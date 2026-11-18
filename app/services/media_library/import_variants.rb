# frozen_string_literal: true

require "digest"
module MediaLibrary
  module ImportVariants
    module_function
    # Archived canonical PNGs must survive changes in native compression. Only
    # the processor's metadata-free, bounded raster representation is portable.
    # Both original variants are decoded under the ordinary child limits before
    # their exact, checksum-verified bytes can replace newly encoded work files.
    def preserve!(item:, display:, thumbnail:, directory:, decoded:)
      source = item.details.fetch("source_record")
      display_bytes = File.binread(display)
      info = canonical!(display_bytes, source.fetch("display"), maximum: 1600)
      raise Upload::Rejected, "import_dimensions" unless [ info[:width], info[:height] ] == source.values_at("width", "height") &&
        [ decoded.fetch("width"), decoded.fetch("height") ] == source.values_at("width", "height")
      canonical!(thumbnail, source.fetch("thumbnail"), maximum: 400)
      work = File.join(directory, "import-thumbnail")
      Dir.mkdir(work, 0o700)
      input = File.join(work, "input.png")
      File.binwrite(input, thumbnail)
      thumb = Processor.run!(input, work)
      expected = Railpress::ImageInput.inspect!(thumbnail)
      raise Upload::Rejected, "import_dimensions" unless [ thumb.fetch("width"), thumb.fetch("height") ] == expected.values_at(:width, :height)
      File.binwrite(File.join(directory, "display.png"), display_bytes)
      File.binwrite(File.join(directory, "thumb.png"), thumbnail)
    end
    def canonical!(bytes, record, maximum:)
      raise Upload::Rejected, "import_media_integrity" unless bytes.is_a?(String) && bytes.bytesize == record["bytes"] && Digest::SHA256.hexdigest(bytes) == record["sha256"]
      info = Railpress::ImageInput.inspect!(bytes)
      raise Upload::Rejected, "import_canonical_png" unless info[:format] == "png" && info[:depth] == 8 && [ 2, 6 ].include?(info[:color]) && info[:interlace].zero? &&
        info[:width] <= maximum && info[:height] <= maximum
      offset = 8
      physical = false
      data = false
      while offset < bytes.bytesize
        length = bytes.byteslice(offset, 4).unpack1("N")
        type = bytes.byteslice(offset + 4, 4)
        raise Upload::Rejected, "import_png_metadata" unless %w[IHDR pHYs IDAT IEND].include?(type)
        if type == "pHYs"
          raise Upload::Rejected, "import_png_metadata" if physical || data || length != 9 || ![ 0, 1 ].include?(bytes.getbyte(offset + 16))
          physical = true
        end
        data = true if type == "IDAT"
        offset += length + 12
      end
      info
    end
  end
end
