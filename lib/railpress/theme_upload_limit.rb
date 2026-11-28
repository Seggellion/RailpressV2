# frozen_string_literal: true

require "tempfile"

module Railpress
  class ThemeUploadLimit
    PATH = "/admin/themes/uploads"
    MAX_BYTES = 5 * 1024 * 1024

    def initialize(app)
      @app = app
    end

    def call(env)
      return @app.call(env) unless env["REQUEST_METHOD"] == "POST"
      path = ActionDispatch::Journey::Router::Utils.normalize_path(env["PATH_INFO"])
      return @app.call(env) unless path == PATH || path.start_with?("#{PATH}.")
      declared = env["CONTENT_LENGTH"].to_s
      return reject(400) unless declared.empty? || declared.match?(/\A[0-9]{1,20}\z/)
      return reject(413) if declared.to_i > MAX_BYTES

      Tempfile.create("railpress-theme-request", binmode: true) do |spool|
        count = 0
        input = env.fetch("rack.input")
        while (chunk = input.read([ 16_384, MAX_BYTES + 1 - count ].min)) && !chunk.empty?
          count += chunk.bytesize
          return reject(413) if count > MAX_BYTES
          spool.write(chunk)
        end
        return reject(400) unless declared.empty? || declared.to_i == count
        env["CONTENT_LENGTH"] = count.to_s
        env["rack.input"] = spool
        spool.rewind
        @app.call(env)
      end
    rescue EOFError
      reject(400)
    rescue Errno::ENOSPC, Errno::EDQUOT, Errno::EACCES
      reject(503)
    end

    private

    def reject(status)
      [ status, { "content-type" => "text/plain", "cache-control" => "no-store", "x-robots-tag" => "noindex, nofollow" },
        [ Rack::Utils::HTTP_STATUS_CODES.fetch(status) ] ]
    end
  end
end
