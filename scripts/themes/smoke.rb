require "bundler/setup"
require_relative "../../lib/railpress/theme_renderer"
raise "production required" unless ENV["RAILS_ENV"] == "production"
bundle = Railpress::ThemePackage.load(ARGV.fetch(0), trusted_keys: JSON.parse(File.read(ARGV.fetch(1))))
require "vips"
bundle.manifest["assets"].each_value do |asset|
  next unless asset["content_type"] == "image/png"
  image = Vips::Image.new_from_buffer(bundle.files.fetch(asset["file"]), "", access: :sequential, fail_on: :warning)
  raise "PNG decode bounds" unless image.width <= 1024 && image.height <= 1024
  image.write_to_memory
end
Railpress::ThemePackage::FAMILIES.each do |family|
  Railpress::ThemeRenderer.render(bundle, Railpress::ThemeRenderer.fixture_context(family))
end
puts JSON.generate(environment: "production", families: Railpress::ThemePackage::FAMILIES, database: "none", digest: bundle.digest)
