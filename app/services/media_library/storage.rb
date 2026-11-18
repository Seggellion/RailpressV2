# frozen_string_literal: true

require "fileutils"
require "active_storage/service/disk_service"
module MediaLibrary
  module Storage
    class Unsafe < StandardError; end
    module_function
    def retained?(service = ensure_private!) = service.respond_to?(:retain_objects?) && service.retain_objects?
    def upload_blob!(key:, io:, filename:)
      service = ensure_private!
      return ActiveStorage::Blob.create_and_upload!(key: key, io: io, filename: filename, content_type: "image/png", identify: false) unless retained?(service)
      blob = ActiveStorage::Blob.create_after_unfurling!(key: key, io: io, filename: filename, content_type: "image/png", identify: false)
      binding = service.upload(key, io, checksum: blob.checksum, content_type: "image/png")
      blob.update!(metadata: blob.metadata.merge("railpress_gcs" => binding))
      blob
    end
    def ensure_private!
      Configuration.guard!
      service = ActiveStorage::Blob.service
      return service unless service.is_a?(ActiveStorage::Service::DiskService)
      root = File.expand_path(service.root.to_s)
      if Rails.env.production?
        configured = ENV["RAILPRESS_STORAGE_ROOT"]
        raise Unsafe, "Production media requires explicit private persistent storage outside releases" unless configured && File.absolute_path(configured) == configured && root == File.expand_path(configured) && File.directory?(root) && !File.realpath(root).start_with?(Rails.root.realpath.to_s + "/") && File.realpath(root) != Rails.root.realpath.to_s
      end
      raise Unsafe, "Unsafe storage root" if File.symlink?(root)
      FileUtils.mkdir_p(root, mode: 0o700)
      stat = File.stat(root)
      raise Unsafe, "Storage must be owned by the app user" unless stat.uid == Process.uid
      if (stat.mode & 0o077) != 0
        raise Unsafe, "Production storage must be private" if Rails.env.production?
        allowed = Rails.root.join(".local/state/media").to_s + "/"
        raise Unsafe, "Unqualified local storage root" unless root.start_with?(allowed)
        File.chmod(0o700, root)
      end
      service
    rescue Configuration::Handoff
      raise Unsafe, "Media configuration differs from the installed choice; ask the operator to reconcile without switching existing media."
    end
    def work_root
      service = ensure_private!
      base = if service.is_a?(ActiveStorage::Service::DiskService)
        service.root.to_s + ".quarantine"
      else
        ENV.fetch("RAILPRESS_QUARANTINE_ROOT") { raise Unsafe, "Private local quarantine required" }
      end
      raise Unsafe, "Unsafe quarantine root" unless File.absolute_path(base) == base && !File.symlink?(base)
      FileUtils.mkdir_p(base, mode: 0o700)
      stat = File.stat(base)
      raise Unsafe, "Quarantine must be owned/private" unless stat.uid == Process.uid && (stat.mode & 0o077).zero?
      base
    end
    def remove_work!(path)
      base = File.realpath(work_root) + "/"
      raise Unsafe, "Unsafe work cleanup" unless File.realpath(path).start_with?(base)
      FileUtils.remove_entry_secure(path)
    end
    def delete_key!(key)
      raise Unsafe, "Invalid owned object key" unless /\A[0-9a-f]{64}\z/.match?(key.to_s)
      service = ensure_private!
      return :retained if retained?(service)
      service.delete(key)
    end
  end
end
