require "rubygems/package"
require "stringio"
require "json"
require "digest"
require_relative "portability_contract"
module Railpress
  module SiteArchive
    class Invalid < StandardError; end
    class UniqueObject < Hash
      def []=(key, value)
        raise Invalid, "duplicate_json_key" if key?(key)
        super
      end
    end
    module_function
    def parse(bytes)
      raise Invalid, "manifest_size" unless bytes.is_a?(String) && bytes.bytesize.between?(1, PortabilityContract::MAX_MANIFEST)
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      raise Invalid, "invalid_utf8" unless text.valid_encoding?
      plain(JSON.parse(text, max_nesting: 40, object_class: UniqueObject))
    rescue JSON::ParserError
      raise Invalid, "malformed_json"
    end
    def plain(value)
      case value
      when Hash then value.to_h { |key, item| [ key, plain(item) ] }
      when Array then value.map { |item| plain(item) }
      else value
      end
    end
    def canonical(value)
      case value
      when Hash then "{" + value.keys.sort.map { |k| JSON.generate(k) + ":" + canonical(value[k]) }.join(",") + "}"
      when Array then "[" + value.map { |v| canonical(v) }.join(",") + "]"
      else JSON.generate(value)
      end
    end
    def path!(name)
      raise Invalid, "unsafe_archive_path" unless name.is_a?(String) && (name == "manifest.json" || name == "manifest.sha256" || name.match?(/\Amedia\/[0-9a-f]{64}\.png\z/))
    end
    def build(manifest, media)
      raise Invalid, "invalid_media_payload_paths" unless media.is_a?(Hash) && media.keys.all? { |key| key.is_a?(String) && key.match?(/\Amedia\/[0-9a-f]{64}\.png\z/) }
      json = canonical(manifest)
      raise Invalid, "manifest_size" if json.bytesize > PortabilityContract::MAX_MANIFEST
      payloads = { "manifest.json" => json, "manifest.sha256" => Digest::SHA256.hexdigest(json) + "\n" }.merge(media)
      raise Invalid, "archive_size" if payloads.values.sum(&:bytesize) + payloads.length * 1024 + 1024 > PortabilityContract::MAX_ARCHIVE
      io = StringIO.new("".b)
      Gem::Package::TarWriter.new(io) do |tar|
        payloads.each do |name, data|
          path!(name)
          tar.add_file_simple(name, 0o600, data.bytesize) { |file| file.write(data) }
        end
      end
      io.string
    end
    def read(bytes)
      raise Invalid, "archive_size" unless bytes.is_a?(String) && bytes.bytesize.between?(1024, PortabilityContract::MAX_ARCHIVE)
      raise Invalid, "unsupported_compression" if bytes.start_with?("\x1f\x8b".b, "PK".b)
      io = StringIO.new(bytes.b); entries = {}; seen = {}; count = 0
      loop do
        raw = io.read(512)
        raise Invalid, "truncated_archive" unless raw && raw.bytesize == 512
        if raw == "\0" * 512
          raise Invalid, "archive_terminator" unless io.read(512) == "\0" * 512
          tail = io.read.to_s
          raise Invalid, "archive_terminator" unless tail.bytesize <= 10_240 && (tail.bytesize % 512).zero? && tail.each_byte.all?(&:zero?)
          break
        end
        checksum = raw.bytes.each_with_index.sum { |byte, i| (148...156).cover?(i) ? 32 : byte }
        raise Invalid, "tar_checksum" unless raw[148, 8].match?(/\A[0-7]+\x00 ?\z/) && raw[148, 8].to_i(8) == checksum
        header = Gem::Package::TarHeader.from(StringIO.new(raw))
        raise Invalid, "archive_type_or_permissions" unless [ "0", "" ].include?(header.typeflag) && header.linkname.empty? && header.mode == 0o600 && header.uid.zero? && header.gid.zero?
        name = header.prefix.empty? ? header.name : "#{header.prefix}/#{header.name}"
        path!(name)
        raise Invalid, "duplicate_archive_path" if seen[name.downcase]
        seen[name.downcase] = true; count += 1
        raise Invalid, "archive_entry_limit" if count > PortabilityContract::MAX_MEDIA * 2 + 2
        limit = name == "manifest.json" ? PortabilityContract::MAX_MANIFEST : name == "manifest.sha256" ? 65 : 12 * 1024 * 1024
        raise Invalid, "archive_entry_size" unless header.size.between?(1, limit) && header.size <= bytes.bytesize - io.pos
        entries[name] = io.read(header.size)
        padding = io.read((512 - header.size % 512) % 512)
        raise Invalid, "archive_padding" unless padding && padding.bytes.all?(&:zero?)
      end
      json = entries.delete("manifest.json"); sum = entries.delete("manifest.sha256")
      raise Invalid, "manifest_integrity" unless json && sum == Digest::SHA256.hexdigest(json) + "\n"
      [ parse(json), entries ]
    rescue Gem::Package::TarInvalidError, EOFError, ArgumentError
      raise Invalid, "malformed_archive"
    end
  end
end
