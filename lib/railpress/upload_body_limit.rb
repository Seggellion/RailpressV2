# frozen_string_literal: true

module Railpress
  class UploadBodyLimit
    class TooLarge < StandardError; end
    MAX_REQUEST_BYTES = 9 * 1024 * 1024
    class Input
      def initialize(io)
        @io, @count = io, 0
      end
      def read(length = nil, buffer = nil)
        bytes = @io.read([ length || MAX_REQUEST_BYTES + 1, MAX_REQUEST_BYTES - @count + 1 ].min)
        @count += bytes.to_s.bytesize
        raise TooLarge if @count > MAX_REQUEST_BYTES
        buffer ? buffer.replace(bytes.to_s) : bytes
      end
      def gets
        bytes = @io.gets(MAX_REQUEST_BYTES - @count + 1)
        @count += bytes.to_s.bytesize
        raise TooLarge if @count > MAX_REQUEST_BYTES
        bytes
      end
      def each
        while (chunk = read(16_384)) && !chunk.empty?
          yield chunk
        end
      end
      def rewind
        @count = 0
        @io.rewind
      end
    end
    def initialize(app)
      @app = app
    end
    def call(env)
      if env["PATH_INFO"] == "/admin/media_assets" && env["REQUEST_METHOD"] == "POST"
        raise TooLarge if env["CONTENT_LENGTH"].to_i > MAX_REQUEST_BYTES
        env["rack.input"] = Input.new(env.fetch("rack.input"))
      end
      @app.call(env)
    rescue TooLarge
      [ 413, { "content-type" => "text/plain", "cache-control" => "no-store", "x-robots-tag" => "noindex" }, [ "Upload request is too large." ] ]
    end
  end
end
