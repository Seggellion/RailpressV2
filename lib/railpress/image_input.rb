# frozen_string_literal: true

require "zlib"
module Railpress
  module ImageInput
    class Invalid < StandardError; end
    MAX_BYTES = 8 * 1024 * 1024
    MAX_DIMENSION = 8192
    MAX_PIXELS = 16_000_000
    module_function
    def inspect!(bytes)
      raise Invalid, "size" unless bytes.bytesize.between?(1, MAX_BYTES)
      result = if bytes.start_with?("\x89PNG\r\n\x1a\n".b)
        png!(bytes)
      elsif bytes.start_with?("\xff\xd8".b)
        reject_active_content!(bytes)
        jpeg!(bytes)
      else
        reject_active_content!(bytes)
        raise Invalid, "unsupported"
      end
      width, height = result.values_at(:width, :height)
      raise Invalid, "pixels" unless width.positive? && height.positive? && width <= MAX_DIMENSION && height <= MAX_DIMENSION && width * height <= MAX_PIXELS
      result
    end
    def reject_active_content!(bytes)
      raise Invalid, "active_content" if bytes.match?(/<\s*(?:script|html|svg|iframe|!doctype)|<\?|javascript:/in)
    end
    def png!(bytes)
      offset = 8
      info = nil
      idat = false
      chunks = 0
      while offset + 12 <= bytes.bytesize
        length = bytes.byteslice(offset, 4).unpack1("N")
        type = bytes.byteslice(offset + 4, 4)
        raise Invalid, "corrupt" unless type.match?(/\A[A-Za-z]{4}\z/n) && offset + length + 12 <= bytes.bytesize
        payload = bytes.byteslice(offset + 8, length)
        crc = bytes.byteslice(offset + 8 + length, 4).unpack1("N")
        raise Invalid, "corrupt" unless Zlib.crc32(type + payload) == crc
        # IDAT is compressed pixel data, not markup. Arbitrary pixel streams
        # can contain these byte pairs; container checks and the bounded native
        # decoder still validate every IDAT stream before any object is stored.
        reject_active_content!(payload) unless type == "IDAT"
        chunks += 1
        raise Invalid, "corrupt" if chunks > 4096 || (!info && type != "IHDR")
        if type == "IHDR"
          raise Invalid, "corrupt" if info || length != 13
          width, height, depth, color, compression, filter, interlace = payload.unpack("NNCCCCC")
          raise Invalid, "unsupported" unless [ 1, 2, 4, 8, 16 ].include?(depth) && [ 0, 2, 3, 4, 6 ].include?(color) && compression.zero? && filter.zero? && [ 0, 1 ].include?(interlace)
          info = { format: "png", type: "image/png", width: width, height: height, depth: depth, color: color, interlace: interlace }
        end
        raise Invalid, "animation" if %w[acTL fcTL fdAT].include?(type)
        idat = true if type == "IDAT"
        offset += length + 12
        if type == "IEND"
          raise Invalid, "trailer" unless length.zero? && idat && offset == bytes.bytesize
          return info
        end
      end
      raise Invalid, "corrupt"
    end
    def png_pixels!(bytes, info)
      channels = { 0 => 1, 2 => 3, 3 => 1, 4 => 2, 6 => 4 }.fetch(info.fetch(:color))
      bits = channels * info.fetch(:depth)
      passes = info[:interlace].zero? ? [ [ 0, 0, 1, 1 ] ] : [ [ 0, 0, 8, 8 ], [ 4, 0, 8, 8 ], [ 0, 4, 4, 8 ], [ 2, 0, 4, 4 ], [ 0, 2, 2, 4 ], [ 1, 0, 2, 2 ], [ 0, 1, 1, 2 ] ]
      expected = passes.sum do |x, y, dx, dy|
        width = [ (info[:width]-x+dx-1)/dx, 0 ].max
        height = [ (info[:height]-y+dy-1)/dy, 0 ].max
        width.positive? && height.positive? ? (((width*bits+7)/8)+1)*height : 0
      end
      expanded = 0
      compressed = 0
      inflater = Zlib::Inflate.new
      consume = ->(chunk) { expanded += chunk.bytesize; raise Invalid, "compressed_data" if expanded > expected }
      offset = 8
      while offset + 12 <= bytes.bytesize
        length = bytes.byteslice(offset, 4).unpack1("N")
        if bytes.byteslice(offset+4, 4) == "IDAT"
          compressed += length
          inflater.inflate(bytes.byteslice(offset+8, length), &consume)
        end
        offset += length + 12
      end
      inflater.finish(&consume) unless inflater.finished?
      raise Invalid, "compressed_data" unless inflater.finished? && expanded == expected && inflater.total_in == compressed
      true
    rescue Zlib::Error
      raise Invalid, "compressed_data"
    ensure
      inflater&.close
    end
    def jpeg!(bytes)
      pos = 2
      info = nil
      scans = false
      while pos < bytes.bytesize
        raise Invalid, "corrupt" unless bytes.getbyte(pos) == 255
        pos += 1 while bytes.getbyte(pos) == 255
        marker = bytes.getbyte(pos)
        raise Invalid, "corrupt" unless marker
        pos += 1
        if marker == 217
          raise Invalid, "trailer" unless info && scans && pos == bytes.bytesize
          return info
        end
        raise Invalid, "corrupt" if marker == 216 || marker.zero? || (208..215).cover?(marker)
        raise Invalid, "corrupt" unless pos + 2 <= bytes.bytesize
        length = bytes.byteslice(pos, 2).unpack1("n")
        raise Invalid, "corrupt" unless length >= 2 && pos + length <= bytes.bytesize
        if [ 192, 194 ].include?(marker)
          raise Invalid, "corrupt" if info || length < 8
          depth, height, width = bytes.byteslice(pos + 2, 5).unpack("Cnn")
          raise Invalid, "unsupported" unless depth == 8
          info = { format: "jpeg", type: "image/jpeg", width: width, height: height }
        end
        pos += length
        if marker == 218
          scans = true
          loop do
            prefix = bytes.index("\xff".b, pos)
            raise Invalid, "corrupt" unless prefix
            following = bytes.getbyte(prefix + 1)
            if following == 0 || (following && (208..215).cover?(following))
              pos = prefix + 2
            else
              pos = prefix
              break
            end
          end
        end
      end
      raise Invalid, "corrupt"
    end
  end
end
