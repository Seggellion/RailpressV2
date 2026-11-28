# frozen_string_literal: true

require "json"
require "digest"
require "openssl"
require "base64"
require "pathname"
require "zlib"
require_relative "image_input"
require_relative "theme_webp"
require_relative "product"

module Railpress
  module ThemePackage
    class Invalid < StandardError; end
    API = 1
    FAMILIES = %w[front home page post archive taxonomy search empty not_found navigation pagination media footer].freeze
    SLOTS = %w[directory_page candidate_card public_profile].freeze
    MAX_BYTES = 2 * 1024 * 1024
    MAX_FILES = 48
    ID = /\A[a-z][a-z0-9-]{1,39}\z/
    VERSION = /\A(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[a-z0-9]+(?:[.-][a-z0-9]+)*)?\z/
    SHA = /\A[0-9a-f]{64}\z/
    class UniqueHash < Hash
      def []=(key, value)
        raise Invalid, "duplicate_json_key" if key?(key)
        super
      end
    end
    Bundle = Data.define(:manifest, :digest, :files, :signature)
    module_function
    def canonical(value)
      case value
      when Hash then JSON.generate(value.keys.sort.to_h { |key| [ key, JSON.parse(canonical(value.fetch(key))) ] })
      when Array then JSON.generate(value.map { |item| JSON.parse(canonical(item)) })
      else JSON.generate(value)
      end
    end
    def parse(bytes)
      raise Invalid, "manifest_size" unless bytes.bytesize.between?(2, 65_536)
      JSON.parse(bytes, max_nesting: 16, object_class: UniqueHash)
    rescue JSON::ParserError
      raise Invalid, "invalid_json"
    end
    def identity!(id, version, digest = nil)
      raise Invalid, "identity" unless id.is_a?(String) && ID.match?(id) && id != "avatar" && version.is_a?(String) && version.bytesize <= 80 && VERSION.match?(version)
      raise Invalid, "digest" if digest && (!digest.is_a?(String) || !SHA.match?(digest))
    end
    def freeze_tree(value)
      value.each { |key, item| key.freeze; freeze_tree(item) } if value.is_a?(Hash)
      value.each { |item| freeze_tree(item) } if value.is_a?(Array)
      value.freeze
    end
    def keys!(object, keys)
      raise Invalid, "unknown_or_missing_fields" unless object.is_a?(Hash) && object.keys.sort == keys.sort
    end
    def manifest!(object, runtime_core: Product::VERSION)
      required = %w[format schema_version theme_api id version name description license authors provenance compatibility templates assets files options]
      optional = [ "menu_locations" ]
      optional += %w[extension_presentation_api slots requires] if object.is_a?(Hash) && object["schema_version"] == 2
      keys!(object, required + optional.select { |key| object.is_a?(Hash) && object.key?(key) })
      if object.key?("menu_locations")
        slots = object["menu_locations"]
        raise Invalid, "menu_locations" unless slots.is_a?(Hash) && slots.length.between?(1, 4) && (slots.keys - %w[primary mobile footer documentation]).empty? && slots.values.all? { |label| label.is_a?(String) && label.valid_encoding? && label.length.between?(1, 80) && !label.match?(/[\x00-\x1f\x7f<>]/) }
      end
      raise Invalid, "format_or_api" unless object["format"] == "railpress.theme" && [ 1, 2 ].include?(object["schema_version"]) && object["theme_api"] == API
      identity!(object["id"], object["version"])
      %w[name description provenance].each { |key| raise Invalid, "metadata" unless object[key].is_a?(String) && object[key].length.between?(1, 1000) && object[key].valid_encoding? }
      raise Invalid, "license" unless object["license"] == "MIT"
      raise Invalid, "authors" unless object["authors"].is_a?(Array) && object["authors"].length.between?(1, 8) && object["authors"].all? { |author| author.is_a?(String) && author.length.between?(1, 100) }
      v2 = object["schema_version"] == 2
      keys!(object["compatibility"], %w[core_api ruby_min] + (v2 ? [ "core" ] : []))
      raise Invalid, "incompatible" unless object["compatibility"]["core_api"] == 1 && object["compatibility"]["ruby_min"].is_a?(String) && object["compatibility"]["ruby_min"].match?(/\A\d+\.\d+\.\d+\z/) && Gem::Version.new(RUBY_VERSION) >= Gem::Version.new(object["compatibility"]["ruby_min"])
      validate_presentation!(object, runtime_core: runtime_core) if v2
      keys!(object["templates"], FAMILIES)
      object["templates"].each { |family, path| raise Invalid, "protected_or_unknown_template" unless path == "templates/#{family}.html.erb" }
      option_keys = %w[palettes fonts layouts home_patterns]
      option_keys << "artwork_styles" if object["options"].is_a?(Hash) && object["options"].key?("artwork_styles")
      option_keys << "appearance_modes" if object["options"].is_a?(Hash) && object["options"].key?("appearance_modes")
      keys!(object["options"], option_keys)
      if option_keys.include?("appearance_modes")
        raise Invalid, "appearance_modes" unless object["id"] == "dusk" && object["options"]["appearance_modes"] == %w[system light dark]
      end
      if option_keys.include?("artwork_styles")
        raise Invalid, "artwork_styles" unless object["id"] == "dusk" && object["options"]["artwork_styles"] == %w[editorial none]
      end
      object["options"].each do |key, choices|
        raise Invalid, "option_choices" unless choices.is_a?(Array) && choices.length.between?(1, 8) && choices.uniq == choices && choices.all? { |choice| choice.is_a?(String) && choice.match?(/\A[a-z][a-z0-9_]{0,29}\z/) }
        raise Invalid, "font_choice" if key == "fonts" && (choices - %w[system_sans system_serif]).any?
      end
      raise Invalid, "asset_map" unless object["assets"].is_a?(Hash) && object["assets"].length.between?(1, 28)
      object["assets"].each do |name, asset|
        keys!(asset, %w[file sha256 byte_size content_type])
        raise Invalid, "asset_name" unless name.match?(/\A[a-z][a-z0-9_]{0,29}\z/)
        expected_type = { ".css" => "text/css", ".png" => "image/png", ".webp" => "image/webp" }[File.extname(asset["file"].to_s)]
        raise Invalid, "asset_path" unless asset["file"].is_a?(String) && asset["file"].bytesize <= 100 && asset["file"].match?(/\Aassets\/[a-z0-9][a-z0-9._-]*\.(?:css|png|webp)\z/)
        raise Invalid, "asset_metadata" unless asset["sha256"].is_a?(String) && SHA.match?(asset["sha256"]) && asset["byte_size"].is_a?(Integer) && asset["byte_size"].between?(1, 1_048_576) && asset["content_type"] == expected_type
      end
      raise Invalid, "stylesheet_required" unless object["assets"].values.any? { |asset| asset["content_type"] == "text/css" }
      expected = [ "LICENSE.txt", *object["templates"].values, *object.fetch("slots", {}).values, *object["assets"].values.map { |asset| asset["file"] } ]
      raise Invalid, "duplicate_asset_path" unless expected.uniq == expected
      raise Invalid, "file_map" unless object["files"].is_a?(Hash) && object["files"].keys.sort == expected.sort && object["files"].values.all? { |sha| sha.is_a?(String) && SHA.match?(sha) }
      object
    rescue ArgumentError, TypeError, NoMethodError
      raise Invalid, "malformed_manifest"
    end
    def validate_presentation!(manifest, runtime_core:)
      raise Invalid, "incompatible_core" unless version_allowed?(manifest.dig("compatibility", "core"), runtime_core)
      if manifest.key?("extension_presentation_api")
        raise Invalid, "presentation_api" unless manifest["extension_presentation_api"] == 1
      end
      slots = manifest.fetch("slots", {})
      raise Invalid, "presentation_slots" unless slots.is_a?(Hash) && (slots.keys - SLOTS).empty? &&
        (slots.empty? || manifest["extension_presentation_api"] == 1)
      slots.each do |slot, path|
        raise Invalid, "presentation_slot_path" unless path == "templates/slots/#{slot}.html.erb"
      end
      requires = manifest.fetch("requires", {})
      raise Invalid, "presentation_dependencies" unless requires.is_a?(Hash) && requires.length <= 8
      requires.each do |capability, range|
        unless capability.match?(/\A[a-z][a-z0-9]*(?:-[a-z0-9]+)*\.[a-z][a-z0-9_-]{0,30}(?:\.[a-z][a-z0-9_-]{0,30}){0,2}\z/) && capability.split(".").first.length <= 30
          raise Invalid, "presentation_capability"
        end
        version_window!(range)
      end
    end
    def version_window!(range)
      keys!(range, %w[min max_exclusive])
      range.each_value do |version|
        raise Invalid, "incompatible_version" unless version.is_a?(String) && version.bytesize <= 80 && VERSION.match?(version)
      end
      endpoints = range.values_at("min", "max_exclusive").map { |version| Gem::Version.new(version) }
      raise Invalid, "incompatible_version" unless endpoints.first < endpoints.last
      endpoints
    end
    def version_allowed?(range, version)
      minimum, maximum = version_window!(range)
      value = Gem::Version.new(version)
      value >= minimum && value < maximum
    end
    def read_file(path, maximum)
      raise Invalid, "symlink_or_nonfile" unless File.lstat(path).file? && !File.symlink?(path)
      File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
        raise Invalid, "file_size" unless file.stat.size <= maximum
        bytes = file.read(maximum + 1)
        raise Invalid, "file_size" if bytes.bytesize > maximum
        bytes
      end
    rescue Errno::ENOENT, Errno::ELOOP, Errno::EACCES
      raise Invalid, "unreadable_package"
    end
    def load(directory, trusted_keys:, runtime_core: Product::VERSION)
      root = File.expand_path(directory)
      raise Invalid, "directory_package_required" unless File.directory?(root) && !File.symlink?(root)
      paths = []
      scan = lambda do |base|
        Dir.children(base).sort.each do |name|
          path = File.join(base, name)
          stat = File.lstat(path)
          raise Invalid, "symlink" if stat.symlink?
          relative = path.delete_prefix(root + "/")
          if stat.directory?
            raise Invalid, "directory_path" unless %w[templates templates/slots assets].include?(relative)
            scan.call(path)
          elsif stat.file?
            paths << relative
          else
            raise Invalid, "non_regular_file"
          end
          raise Invalid, "too_many_files" if paths.length > MAX_FILES
        end
      end
      scan.call(root)
      normalized = paths.map { |path| path.unicode_normalize(:nfc).downcase }
      raise Invalid, "duplicate_normalized_path" unless normalized.uniq == normalized
      manifest_bytes = read_file(File.join(root, "manifest.json"), 65_536)
      manifest = manifest!(parse(manifest_bytes), runtime_core: runtime_core)
      signature_bytes = read_file(File.join(root, "signature.json"), 2048)
      signature = parse(signature_bytes)
      keys!(signature, %w[algorithm key_id signature])
      raise Invalid, "signature_algorithm" unless signature["algorithm"] == "ed25519" && signature["key_id"].is_a?(String) && SHA.match?(signature["key_id"])
      raise Invalid, "invalid_trust_store" unless trusted_keys.is_a?(Hash)
      pem = trusted_keys.fetch(signature["key_id"]) { raise Invalid, "untrusted_signer" }
      raise Invalid, "public_key_required" unless pem.is_a?(String) && pem.bytesize <= 4096 && !pem.include?("PRIVATE KEY")
      key = OpenSSL::PKey.read(pem)
      raise Invalid, "key_identity" unless key.oid == "ED25519" && Digest::SHA256.hexdigest(key.public_to_der) == signature["key_id"]
      signed = canonical(manifest)
      raw = Base64.strict_decode64(signature["signature"].to_s)
      raise Invalid, "invalid_signature" unless raw.bytesize == 64 && key.verify(nil, raw, signed)
      expected = [ "manifest.json", "signature.json", *manifest["files"].keys ]
      raise Invalid, "unlisted_or_missing_files" unless paths.sort == expected.sort
      bytes = {}; total = manifest_bytes.bytesize + signature_bytes.bytesize
      manifest["files"].each do |path, sha|
        content = read_file(File.join(root, path), MAX_BYTES)
        total += content.bytesize
        raise Invalid, "package_size" if total > MAX_BYTES
        raise Invalid, "file_checksum" unless Digest::SHA256.hexdigest(content) == sha
        bytes[path] = content
      end
      notice = bytes.fetch("LICENSE.txt")
      raise Invalid, "license_notice" unless notice.include?("MIT License") && notice.include?("Permission is hereby granted") && notice.include?("Copyright")
      (manifest["templates"].values + manifest.fetch("slots", {}).values).each do |path|
        raise Invalid, "template_encoding_or_size" unless bytes[path].dup.force_encoding("UTF-8").valid_encoding? && bytes[path].bytesize.between?(1, 65_536)
      end
      manifest["assets"].each_value do |asset|
        content = bytes.fetch(asset["file"])
        raise Invalid, "asset_checksum_or_size" unless content.bytesize == asset["byte_size"] && Digest::SHA256.hexdigest(content) == asset["sha256"]
        if asset["content_type"] == "text/css"
          css = content.dup.force_encoding("UTF-8")
          raise Invalid, "unsafe_css" unless css.valid_encoding? && css.bytesize <= 262_144 && !css.match?(/url\s*\(|@import|expression\s*\(|behavior\s*:|binding\s*:|[\\<>\x00]/i)
          stripped = css.gsub(%r{/\*.*?\*/}m, "").gsub(/"(?:[^"]*)"|'(?:[^']*)'/m, "")
          depth = 0
          stripped.each_char do |char|
            depth += 1 if char == "{"
            depth -= 1 if char == "}"
            raise Invalid, "malformed_css" if depth.negative?
          end
          raise Invalid, "malformed_css" unless depth.zero? && !stripped.include?("/*")
        elsif asset["content_type"] == "image/webp"
          Railpress::ThemeWebp.validate!(content)
        else
          info = Railpress::ImageInput.inspect!(content)
          raise Invalid, "asset_image_bounds" unless info[:format] == "png" && info[:width] <= 1024 && info[:height] <= 1024
          Railpress::ImageInput.png_pixels!(content, info)
        end
      end
      bytes["manifest.json"] = manifest_bytes
      bytes["signature.json"] = signature_bytes
      Bundle.new(manifest: freeze_tree(manifest), digest: Digest::SHA256.hexdigest(signed), files: freeze_tree(bytes), signature: freeze_tree(signature))
    rescue KeyError, JSON::ParserError, OpenSSL::PKey::PKeyError, ArgumentError, TypeError, Railpress::ImageInput::Invalid, Railpress::ThemeWebp::Invalid
      raise Invalid, "invalid_package"
    end
  end
end
