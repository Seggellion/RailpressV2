# Original synthetic qualification builder; never installs trust or activates a theme.
require "fileutils"
require_relative "theme_package"
module Railpress
  module ThemeFixture
    module_function
    def build(directory, root:, signer:, id: "harbor", version: "1.0.0", mutate: nil)
      source = File.join(root, "themes/reference", id == "dusk" ? "dusk-api" : "harbor-api")
      FileUtils.mkdir_p(directory, mode: 0o700)
      FileUtils.cp_r(Dir.glob(File.join(source, "*")), directory)
      files = Dir.glob(File.join(directory, "**", "*")).select { |path| File.file?(path) }.to_h { |path| [ path.delete_prefix(directory + "/"), Digest::SHA256.file(path).hexdigest ] }
      css = File.binread(File.join(directory, "assets/public.css"))
      manifest = { "format" => "railpress.theme", "schema_version" => 1, "theme_api" => 1, "id" => id, "version" => version,
        "name" => "#{id.capitalize} API reference", "description" => "Original synthetic API fixture, not Dusk design qualification.", "license" => "MIT", "authors" => [ "Railpress contributors" ],
        "provenance" => "Original Railpress M06 templates and CSS; no UltimaCraft or third-party assets.",
        "compatibility" => { "core_api" => 1, "ruby_min" => "3.4.0" },
        "templates" => ThemePackage::FAMILIES.to_h { |family| [ family, "templates/#{family}.html.erb" ] },
        "assets" => { "public" => { "file" => "assets/public.css", "sha256" => Digest::SHA256.hexdigest(css), "byte_size" => css.bytesize, "content_type" => "text/css" } },
        "files" => files, "options" => { "palettes" => %w[ocean stone], "fonts" => %w[system_sans system_serif], "layouts" => %w[reading wide], "home_patterns" => %w[summary feature] } }
      mutate&.call(manifest, directory)
      sign(directory, manifest, signer)
    end
    def sign(directory, manifest, signer)
      File.write(File.join(directory, "manifest.json"), JSON.pretty_generate(manifest))
      signature = { "algorithm" => "ed25519", "key_id" => Digest::SHA256.hexdigest(signer.public_to_der), "signature" => Base64.strict_encode64(signer.sign(nil, ThemePackage.canonical(manifest))) }
      File.write(File.join(directory, "signature.json"), JSON.generate(signature))
      directory
    end
    def replace(manifest, directory, path, source)
      File.write(File.join(directory, path), source)
      manifest["files"][path] = Digest::SHA256.hexdigest(source)
      manifest["assets"].each_value do |asset|
        next unless asset["file"] == path
        asset["sha256"] = manifest["files"][path]; asset["byte_size"] = source.bytesize
      end
    end
  end
end
