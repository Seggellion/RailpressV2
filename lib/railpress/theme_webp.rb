require "digest"
require "tempfile"
require "timeout"
module Railpress
  # This adds static WebP to signed executable theme packages, not user uploads.
  module ThemeWebp
    class Invalid < StandardError; end
    @lock = Mutex.new
    @valid = {}
    @versions = {}
    module_function
    def inspect!(bytes)
      raise Invalid, "webp_size" unless bytes.bytesize.between?(30, 1_048_576)
      raise Invalid, "webp_container" unless bytes.byteslice(0, 4) == "RIFF" && bytes.byteslice(8, 4) == "WEBP" && bytes.byteslice(4, 4).unpack1("V") + 8 == bytes.bytesize
      # Only the simple, opaque, single-frame VP8 form produced by our pipeline.
      # VP8X, animation, metadata, unknown chunks and trailing payload fail closed.
      length = bytes.byteslice(16, 4).unpack1("V")
      raise Invalid, "webp_chunks" unless bytes.byteslice(12, 4) == "VP8 " && length >= 10 && 20 + length + (length % 2) == bytes.bytesize
      raise Invalid, "webp_padding" if length.odd? && bytes.getbyte(-1) != 0
      raise Invalid, "webp_frame" unless bytes.byteslice(23, 3) == "\x9d\x01\x2a".b && (bytes.getbyte(20) & 1).zero?
      width, height = bytes.byteslice(26, 4).unpack("vv").map { |v| v & 0x3fff }
      raise Invalid, "webp_pixels" unless width.between?(1, 1024) && height.between?(1, 1024)
      { width: width, height: height, format: "webp", type: "image/webp" }
    end
    def decoder
      path = ENV.fetch("RAILPRESS_WEBP_DECODER", "")
      raise Invalid, "native_webp_decoder_required" unless path.start_with?("/") && File.expand_path(path) == path && File.file?(path) && File.executable?(path) && File.realpath(path) == path
      stat = File.stat(path)
      raise Invalid, "unsafe_webp_decoder" unless [ 0, Process.uid ].include?(stat.uid) && (stat.mode & 0o022).zero?
      [ path, stat.ino, stat.size, stat.mtime.to_r, stat.ctime.to_r ].freeze
    rescue SystemCallError
      raise Invalid, "native_webp_decoder_required"
    end
    def run!(path, *arguments)
      pid = nil
      Tempfile.create("railpress-webp-log") do |log|
        environment = { "PATH" => "/usr/bin:/bin", "LANG" => "C.UTF-8", "MALLOC_ARENA_MAX" => "2" }
        pid = Process.spawn(environment, path, *arguments, unsetenv_others: true, out: log, err: [ :child, :out ],
          rlimit_as: 768 * 1024 * 1024, rlimit_cpu: [ 4, 4 ], rlimit_fsize: 65_536)
        status = nil
        Timeout.timeout(5) { _, status = Process.wait2(pid) }
        pid = nil
        log.rewind
        output = log.read(65_537)
        raise Invalid, "webp_decode" unless status.success? && output.bytesize <= 65_536
        output
      end
    rescue Timeout::Error
      raise Invalid, "webp_decode_timeout"
    rescue SystemCallError
      raise Invalid, "webp_decode"
    ensure
      if pid
        Process.kill("KILL", pid) rescue Errno::ESRCH
        Process.wait(pid) rescue Errno::ECHILD
      end
    end
    def validate!(bytes)
      info = inspect!(bytes)
      identity = decoder
      key = [ identity, Digest::SHA256.hexdigest(bytes) ].freeze
      return info if @lock.synchronize { @valid[key] }
      unless @lock.synchronize { @versions[identity] }
        version = run!(identity.first, "-version").strip
        raise Invalid, "webp_decoder_version" unless version.match?(/\A1\.(?:[6-9]|[1-9][0-9]+)\.[0-9]+\z/)
        @lock.synchronize { @versions.clear if @versions.length >= 8; @versions[identity] = true }
      end
      Tempfile.create([ "railpress-theme", ".webp" ]) do |file|
        file.binmode; file.write(bytes); file.flush
        output = run!(identity.first, file.path, "-ppm", "-o", "/dev/null")
        dimensions = output.match(/Dimensions:\s*(\d+)\s*x\s*(\d+)/)
        raise Invalid, "webp_decoded_dimensions" unless dimensions && dimensions[1].to_i == info[:width] && dimensions[2].to_i == info[:height]
      end
      # Content-only validation cache: no theme, site, actor, overlay or HTML state.
      # Replacing a file still rechecks its signed hash before reaching this cache.
      @lock.synchronize { @valid.clear if @valid.length >= 256; @valid[key] = true }
      info
    end
  end
end
