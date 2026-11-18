# Original Dusk source packager. Never creates a key, installs trust or activates.
require "fileutils"
require_relative "theme_package"
module Railpress
  module DuskPackage
    module_function
    def build(directory, root:, signer:)
      raise ArgumentError, "ed25519_signer_required" unless signer.oid == "ED25519" && signer.private_to_der
      raise ArgumentError, "new_empty_directory_required" if File.exist?(directory)
      source = File.join(root, "themes/dusk")
      FileUtils.mkdir_p(directory, mode: 0o700)
      FileUtils.cp_r(Dir.glob(File.join(source, "*")), directory)
      files = Dir.glob(File.join(directory, "**", "*")).select { |path| File.file?(path) }.to_h { |path| [ path.delete_prefix(directory + "/"), Digest::SHA256.file(path).hexdigest ] }
      css = File.binread(File.join(directory, "assets/public.css"))
      assets = { "public" => { "file" => "assets/public.css", "sha256" => Digest::SHA256.hexdigest(css), "byte_size" => css.bytesize, "content_type" => "text/css" } }
      Dir.glob(File.join(directory, "assets", "art-*"), sort: true).each do |path|
        filename = File.basename(path)
        name = filename.delete_prefix("art-").sub(/\.(?:webp|png)\z/, "").tr("-", "_").sub(/_fallback\z/, "_png")
        bytes = File.binread(path)
        assets[name] = { "file" => "assets/#{filename}", "sha256" => Digest::SHA256.hexdigest(bytes), "byte_size" => bytes.bytesize, "content_type" => filename.end_with?(".webp") ? "image/webp" : "image/png" }
      end
      definition = JSON.parse(File.read(File.join(root, "lib/railpress/dusk.json")))
      manifest = { "format" => "railpress.theme", "schema_version" => 1, "theme_api" => definition.fetch("theme_api"), "id" => "dusk", "version" => definition.fetch("version"),
        "name" => "Dusk", "description" => "An original, calm editorial and brochure theme for Railpress.", "license" => "MIT", "authors" => [ "Railpress contributors" ],
        "menu_locations" => { "primary" => "Primary navigation", "footer" => "Footer navigation", "mobile" => "Mobile navigation (optional)", "documentation" => "Documentation navigation (optional)" },
        "provenance" => "Original Dusk templates/CSS and Owner-approved A04 AI-generated decorative artwork, MIT permission from Altama Systems Incorporated. System fonts; no external image requests or source-specific assets.",
        "compatibility" => { "core_api" => 1, "ruby_min" => "3.4.0" },
        "templates" => ThemePackage::FAMILIES.to_h { |family| [ family, "templates/#{family}.html.erb" ] },
        "assets" => assets,
        "files" => files, "options" => { "palettes" => %w[afterglow woodland slate], "fonts" => %w[system_serif system_sans], "layouts" => %w[studio reading], "home_patterns" => %w[journal minimal], "appearance_modes" => %w[system light dark], "artwork_styles" => %w[editorial none] } }
      File.write(File.join(directory, "manifest.json"), JSON.pretty_generate(manifest) + "\n")
      signature = { "algorithm" => "ed25519", "key_id" => Digest::SHA256.hexdigest(signer.public_to_der), "signature" => Base64.strict_encode64(signer.sign(nil, ThemePackage.canonical(manifest))) }
      File.write(File.join(directory, "signature.json"), JSON.generate(signature) + "\n")
      directory
    end
  end
end
