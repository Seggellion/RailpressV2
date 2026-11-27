# frozen_string_literal: true

require "railpress/theme_archive"

module Themes
  module UploadStorage
    class Unavailable < StandardError; end
    module_function

    def root
      base = Storage.root
      path = File.join(base, "upload-quarantine")
      Dir.mkdir(path, 0o700) unless File.exist?(path)
      stat = File.lstat(path)
      raise Unavailable, "quarantine_unavailable" unless stat.directory? && !stat.symlink? && stat.uid == Process.uid &&
        (stat.mode & 0o077).zero? && File.realpath(path) == path
      path
    rescue Errno::EEXIST
      retry
    rescue SystemCallError, Railpress::ThemePackage::Invalid
      raise Unavailable, "quarantine_unavailable", cause: nil
    end

    def save!(key, input)
      destination = path(key)
      directory = File.dirname(destination)
      raise Unavailable, "quarantine_full" if Dir.children(directory).count { |name| name.end_with?(".zip") } >= 32
      Railpress::Releases::Filesystem.capacity!(directory, 3 * Railpress::ThemeArchive::MAX_BYTES)
      size = 0
      digest = Digest::SHA256.new
      Tempfile.create("receive-", directory, binmode: true) do |temporary|
        while (bytes = input.read(16_384)) && !bytes.empty?
          size += bytes.bytesize
          raise Railpress::ThemePackage::Invalid, "zip_size" if size > Railpress::ThemeArchive::MAX_BYTES
          temporary.write(bytes)
          digest.update(bytes)
        end
        raise Railpress::ThemePackage::Invalid, "zip_size" if size < 22
        temporary.chmod(0o400)
        temporary.flush
        temporary.fsync
        # An exclusive link publishes the exact temporary inode without replacing a receipt.
        File.link(temporary.path, destination)
        File.open(directory, File::RDONLY, &:fsync)
      end
      [ size, digest.hexdigest ]
    rescue SystemCallError, Railpress::Releases::Invalid
      raise Unavailable, "quarantine_write_failed", cause: nil
    end

    def with_extracted(upload)
      source = path(upload.operation_key)
      File.open(source, File::RDONLY | File::NOFOLLOW) do |archive|
        stat = archive.stat
        raise Unavailable, "quarantine_identity" unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o777) == 0o400 &&
          stat.size == upload.byte_size && stat.size <= Railpress::ThemeArchive::MAX_BYTES
        digest = Digest::SHA256.new
        while (bytes = archive.read(16_384))
          digest.update(bytes)
        end
        raise Unavailable, "quarantine_identity" unless digest.hexdigest == upload.transport_sha256
        archive.rewind
        Dir.mktmpdir("extract-", File.dirname(source)) do |directory|
          Railpress::ThemeArchive::Reader.new(archive).extract!(directory)
          yield directory
        end
      end
    rescue SystemCallError
      raise Unavailable, "quarantine_read_failed", cause: nil
    end

    def with_validator
      File.open(File.join(root, "validation.lock"), File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
        stat = lock.stat
        raise Unavailable, "validator_lock_unavailable" unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
        raise Unavailable, "validator_busy" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        yield
      end
    rescue SystemCallError
      raise Unavailable, "validator_lock_unavailable", cause: nil
    end

    def remove!(key)
      source = path(key)
      stat = File.lstat(source)
      raise Unavailable, "quarantine_identity" unless stat.file? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o777) == 0o400
      File.unlink(source)
    rescue Errno::ENOENT
      nil
    rescue SystemCallError
      raise Unavailable, "quarantine_cleanup_failed", cause: nil
    end

    def path(key)
      raise Unavailable, "quarantine_identity" unless Railpress::Releases::UUID.match?(key.to_s)
      File.join(root, "#{key}.zip")
    end
  end
end
