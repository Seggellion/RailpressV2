#!/usr/bin/env ruby
require "bundler/setup"
require "vips"
require "json"
require "digest"
require "optparse"
require "pathname"

options = {}
OptionParser.new { |parser| parser.on("--output DIRECTORY") { |value| options[:output] = value } }.parse!
raise "Use --output with a new disposable directory" unless options[:output] && ARGV.empty?
root = Pathname.new(__dir__).join("../..").realpath
manifest = JSON.parse(root.join("docs/brand/ASSET_MANIFEST.json").read)
raise "Expected reviewed raster identity" unless manifest["format"] == "railpress.core-brand.v2" && !manifest["authentic_vector"]
manifest.fetch("files").each do |row|
  path = root.join(row.fetch("path"))
  raise "Asset integrity mismatch" unless path.file? && !path.symlink? && Digest::SHA256.file(path).hexdigest == row.fetch("sha256")
end
output = Pathname.new(options[:output]).expand_path
raise "Preserve existing output" if output.exist? || output.symlink?
output.mkpath(mode: 0o700)
source = Vips::Image.new_from_file(root.join(manifest.fetch("source")).to_s).copy(interpretation: :srgb)
xmin, ymin, xmax, ymax = manifest.fetch("pipeline").fetch("optical_bounds")
cropped = source.crop(xmin, ymin, xmax - xmin + 1, ymax - ymin + 1)
exports = {}
[ 16, 32, 48, 180, 192, 256, 512 ].each do |size|
  side = (size * manifest.fetch("pipeline").fetch("canvas_art_max_fraction")).round
  scaled = cropped.premultiply.resize(side.to_f / [ cropped.width, cropped.height ].max, kernel: :lanczos3).unpremultiply.cast(:uchar)
  bitmap = scaled.embed((size - scaled.width) / 2, (size - scaled.height) / 2, size, size, extend: :background, background: [ 0, 0, 0, 0 ]).copy(interpretation: :srgb)
  bytes = bitmap.pngsave_buffer(compression: 9, strip: true, filter: :all)
  exports[size] = bytes
  output.join("emblem-#{size}.png").binwrite(bytes)
  row = manifest.fetch("files").find { |file| file["path"].start_with?("public/") && file["width"] == size }
  raise "Raster exports differ" if row && Digest::SHA256.hexdigest(bytes) != row.fetch("sha256")
end
sizes = [ 16, 32, 48, 256 ]
offset = 6 + 16 * sizes.length
entries = "".b
payload = "".b
sizes.each do |size|
  bytes = exports.fetch(size)
  dimension = size == 256 ? 0 : size
  entries << [ dimension, dimension, 0, 0, 1, 32, bytes.bytesize, offset ].pack("CCCCvvVV")
  payload << bytes
  offset += bytes.bytesize
end
ico = [ 0, 1, sizes.length ].pack("vvv") + entries + payload
row = manifest.fetch("files").find { |file| file["content_type"] == "image/vnd.microsoft.icon" }
raise "ICO differs" unless Digest::SHA256.hexdigest(ico) == row.fetch("sha256")
output.join("favicon.ico").binwrite(ico)
puts JSON.pretty_generate(status: "PASS", vips: Vips.version_string, PNG_sizes: exports.keys, ICO_sizes: sizes, exact_reviewed_bytes: true, vector_generated: false)
