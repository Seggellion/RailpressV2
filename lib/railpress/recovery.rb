# frozen_string_literal: true

require_relative "native_host"
require_relative "gcs"
require_relative "security_clock"
require_relative "product"
require_relative "recovery/manifest"
require_relative "recovery/target"
require_relative "recovery/validator"
require_relative "recovery/candidate"
require_relative "recovery/fresh"

module Railpress
  # Operator-only, offline synthetic admission. Production admission/cutover is
  # deliberately unavailable until its distinct operational qualification.
  module Recovery
    Error = NativeHost::Error
    F = NativeHost::F
    module_function
    def sha(path) = Digest::SHA256.file(path).hexdigest
    def digest(value) = Digest::SHA256.hexdigest(Releases.canonical(value))
    def private_file(path, maximum: 8 * 1024 * 1024)
      stat = File.lstat(path)
      raise Error, "private_file_required" unless stat.uid == Process.uid && (stat.mode & 0o077).zero?
      F.read(path, maximum: maximum)
    end
  end
end
