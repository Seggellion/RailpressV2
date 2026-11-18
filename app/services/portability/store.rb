require "fileutils"
module Portability
  module Store
    module_function
    def root
      base = Railpress::BootstrapState.for_application.root
      raise Railpress::SiteArchive::Invalid, "private_storage_path" if File.symlink?(base)
      if Rails.env.production?
        raise Railpress::SiteArchive::Invalid, "persistent_private_storage_required" unless ENV["RAILPRESS_PRIVATE_STATE_ROOT"] && !File.expand_path(base).start_with?(Rails.root.realpath.to_s + "/")
      end
      directory = File.join(base, "portability")
      FileUtils.mkdir_p(directory, mode: 0o700)
      stat = File.lstat(directory)
      raise Railpress::SiteArchive::Invalid, "private_storage_permissions" unless stat.directory? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o077).zero? && File.realpath(directory) == File.expand_path(directory)
      directory
    end
    def path(id)
      raise Railpress::SiteArchive::Invalid, "invalid_storage_identity" unless id.is_a?(String) && Format::UUID.match?(id)
      File.join(root, id + ".railpress")
    end
    def write(id, io)
      destination = path(id); temporary = destination + "." + SecureRandom.hex(16)
      digest = Digest::SHA256.new; size = 0
      begin
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
          file.binmode
          while (data = io.read(16_384)) && !data.empty?
            size += data.bytesize
            raise Railpress::SiteArchive::Invalid, "archive_size" if size > Railpress::PortabilityContract::MAX_ARCHIVE
            digest.update(data); file.write(data)
          end
          raise Railpress::SiteArchive::Invalid, "empty_archive" if size.zero?
          file.flush; file.fsync
        end
        yield digest.hexdigest, size if block_given?
        # Never overwrite another batch or export, including a dangling symlink.
        File.link(temporary, destination)
        File.open(root, File::RDONLY, &:fsync)
        [ digest.hexdigest, size ]
      ensure
        File.unlink(temporary) if File.exist?(temporary)
      end
    end
    def upload_lock(id)
      File.open(path(id) + ".lock", File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
        stat = lock.stat
        raise Railpress::SiteArchive::Invalid, "upload_lock_permissions" unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
        raise Imports::Conflict, "This archive upload is still receiving bytes." unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        begin
          yield
        ensure
          lock.flock(File::LOCK_UN)
        end
      end
    end
    def clean_upload_parts!(id)
      # Only after acquiring the server-owned per-receipt lock. No wall-clock
      # age guess or arbitrary archive-supplied cleanup path is involved.
      prefix = path(id) + "."
      Dir.glob(prefix + "*").each do |file|
        next unless file.delete_prefix(prefix).match?(/\A[0-9a-f]{32}\z/)
        stat = File.lstat(file)
        raise Railpress::SiteArchive::Invalid, "unsafe_upload_part" unless stat.file? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
        File.unlink(file)
      end
    end
    def read(record)
      data = File.open(path(record.public_id), File::RDONLY | File::NOFOLLOW) { |file| file.binmode; file.read }
      raise Railpress::SiteArchive::Invalid, "stored_archive_integrity" unless data.bytesize == record.archive_bytes && Digest::SHA256.hexdigest(data) == record.archive_sha256
      data
    end
    def remove(id)
      file = path(id)
      raise Railpress::SiteArchive::Invalid, "unsafe_storage_cleanup" if File.symlink?(file)
      File.unlink(file) if File.file?(file)
    end
  end
end
