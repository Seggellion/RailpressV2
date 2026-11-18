# frozen_string_literal: true

module Railpress
  module NativeHost
    class Snapshot
      ROOTS = %w[media themes bootstrap].freeze
      LIMIT = 256 * 1024 * 1024
      def initialize(config, signer:, fault: nil)
        @config, @signer, @fault = config, signer, fault
        @db = Database.new(config)
      end
      def inventory(root)
        F.directory!(root)
        files, directories = {}, {}
        Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.each do |path|
          relative = path.delete_prefix(root + "/")
          next if relative == "." || relative == ".."
          raise Error, "snapshot_symlink" if File.symlink?(path)
          relative_path!(relative)
          stat = File.lstat(path)
          raise Error, "snapshot_owner" unless stat.uid == Process.uid && (stat.mode & 0o022).zero?
          if stat.directory?
            directories[relative] = stat.mode & 0o777
          elsif stat.file?
            raise Error, "snapshot_file_limit" if stat.size > 128 * 1024 * 1024
            files[relative] = { "sha256" => Digest::SHA256.file(path).hexdigest, "bytes" => stat.size, "mode" => stat.mode & 0o777 }
          else
            raise Error, "snapshot_special_file"
          end
        end
        raise Error, "snapshot_resource_limit" if files.length > 5000 || files.values.sum { |entry| entry["bytes"] } > LIMIT
        { "files" => files, "directories" => directories }
      end
      def create!(id:, active:, contract:, clock_binding:, site_report:)
        NativeHost.uuid!(id)
        @db.assert_installation!
        parent = @config.path("snapshots")
        entries = Dir.children(parent)
        raise Error, "snapshot_retention_capacity" if entries.length >= 32 || entries.count { |name| name.end_with?(".partial") } >= 8
        destination = File.join(parent, id)
        raise Error, "snapshot_exists" if File.exist?(destination) || File.symlink?(destination)
        temporary = File.join(parent, "#{id}.partial")
        Dir.mkdir(temporary, 0o700)
        F.capacity!(parent, LIMIT * 2 + 1024**3)
        started = SecurityClock.elapsed
        database_evidence = @db.integrity.capture
        @db.dump!(id, File.join(temporary, "database.dump"))
        raise Error, "snapshot_database_changed" unless @db.integrity.capture == database_evidence
        shared = File.join(temporary, "shared")
        Dir.mkdir(shared, 0o700)
        copy_file(@config.path("shared", "environment.json"), File.join(shared, "environment.json"))
        ROOTS.each do |name|
          source = @config.path("shared", name)
          copy_tree(source, File.join(shared, name), skip_clock: name == "bootstrap")
        end
        tree = inventory(temporary)
        metadata = { "format" => "railpress.snapshot.v1", "snapshot_id" => id, "deployment_id" => @config.data["deployment_id"],
          "installation_id" => @config.data["install_id"], "engine" => @config.data["engine"], "instance_id" => @config.data["database_instance_id"],
          "active_release" => active, "contract" => contract, "tables" => @db.table_names,
          "site_report" => site_report.merge("database_integrity" => database_evidence, "media_reference_fingerprint_full" => @db.media_reference_fingerprint,
            "media_reference_fingerprint_permanent" => @db.media_reference_fingerprint(permanent: true)),
          "captured_elapsed" => started, "completed_elapsed" => SecurityClock.elapsed, "domain" => SecurityClock.boot_domain,
          "clock_binding_before_backup" => clock_binding, "credential_recovery" => "revoke_all_and_rotate_clock_epoch",
          "files" => tree["files"], "directories" => tree["directories"] }
        bytes = Releases.canonical(NativeHost.sign(metadata, @signer))
        raise Error, "snapshot_manifest_limit" if bytes.bytesize > 1_048_576
        F.atomic(File.join(temporary, "snapshot.json"), bytes)
        F.atomic(File.join(temporary, ".complete"), id)
        File.rename(temporary, destination)
        File.open(parent, File::RDONLY, &:fsync)
        metadata
      end
      def validate!(id, trust:, trust_state:, fresh: true)
        NativeHost.uuid!(id)
        directory = F.directory!(@config.path("snapshots", id), private: true)
        raise Error, "snapshot_incomplete" unless F.read(File.join(directory, ".complete"), maximum: 36) == id
        envelope = NativeHost.load_document(File.join(directory, "snapshot.json"))
        Releases.keys!(envelope, %w[statement signature])
        metadata = envelope["statement"]
        Releases.keys!(metadata, %w[format snapshot_id deployment_id installation_id engine instance_id active_release contract tables site_report captured_elapsed completed_elapsed domain clock_binding_before_backup credential_recovery files directories])
        trust.verify!(Releases.canonical(metadata), envelope["signature"], trust_state, purpose: "status")
        raise Error, "snapshot_context" unless metadata["format"] == "railpress.snapshot.v1" && metadata["snapshot_id"] == id &&
          metadata["deployment_id"] == @config.data["deployment_id"] && metadata["installation_id"] == @config.data["install_id"] &&
          metadata["engine"] == @config.data["engine"] && metadata["instance_id"] == @config.data["database_instance_id"] &&
          metadata["credential_recovery"] == "revoke_all_and_rotate_clock_epoch"
        age = SecurityClock.elapsed - metadata.fetch("captured_elapsed")
        raise Error, "snapshot_time_domain" if fresh && (metadata["domain"] != SecurityClock.boot_domain || age < 0)
        raise Error, "snapshot_stale" if fresh && age > @config.data["max_snapshot_age_seconds"]
        current = inventory(directory)
        current["files"].delete("snapshot.json")
        current["files"].delete(".complete")
        raise Error, "snapshot_integrity" unless current["files"] == metadata["files"] && current["directories"] == metadata["directories"]
        raise Error, "snapshot_environment" unless metadata.dig("files", "shared/environment.json", "sha256") == @config.data["environment_sha256"]
        @db.integrity.validate!(metadata.dig("site_report", "database_integrity"))
        metadata
      rescue KeyError, TypeError
        raise Error, "snapshot_corrupt"
      end
      def preflight!(metadata, operation_id: nil, resume: false)
        @db.integrity.validate!(metadata.dig("site_report", "database_integrity"))
        target, identity = @config.database!
        incoming = metadata.fetch("files").values.sum { |row| Integer(row.fetch("bytes")) }
        retained = nil
        if resume && operation_id
          candidate = @config.path("run", "pre-restore-#{NativeHost.uuid!(operation_id)}")
          if File.exist?(candidate) || File.symlink?(candidate)
            F.directory!(candidate, private: true)
            context = { "operation_id" => operation_id, "snapshot_id" => metadata.fetch("snapshot_id"), "deployment_id" => @config.data["deployment_id"] }
            raise Error, "restore_resume_context" unless NativeHost.load_document(File.join(candidate, "restore-context.json"), maximum: 8192) == context
            retained = candidate
          end
        end
        current = ROOTS.sum do |name|
          path = @config.path("shared", name)
          path = File.join(retained, name) if !File.exist?(path) && !File.symlink?(path) && retained
          inventory(path)["files"].values.sum { |row| row["bytes"] }
        end
        allocated = @db.allocated_bytes
        # Conservative admission for this bounded synthetic profile; not a
        # reservation or a universal estimate from compressed dump size alone.
        database_work = [ allocated, DatabaseIntegrity::MAX_BYTES ].max * 4 + 1024**3
        required = database_work + 2 * (incoming + current) + 64 * 1024**2
        capacity = { "shared" => F.capacity!(@config.path("shared"), required),
          "database" => F.capacity!(target.fetch("data_directory"), required) }
        capacity["host"] = F.capacity!("/mnt/c", required + 8 * 1024**3) if File.directory?("/mnt/c")
        { "model" => "bounded-synthetic-estimate-v1", "database_allocated_bytes" => allocated,
          "incoming_bytes" => incoming, "current_shared_bytes" => current, "required_free_bytes" => required,
          "available_bytes" => capacity, "space_reserved" => false,
          "target_identity_sha256" => Digest::SHA256.hexdigest(Releases.canonical(identity)) }
      rescue KeyError, ArgumentError, TypeError
        raise Error, "restore_capacity_unknown"
      end
      def restore!(**)
        raise Error, "legacy_in_place_restore_unsupported"
      end
      def copy_tree(source, destination, skip_clock: false)
        F.directory!(source)
        Dir.mkdir(destination, 0o700)
        tree = inventory(source)
        excluded = ->(name) { skip_clock && (name == "security-clock.json" || name.end_with?(".lock") || name == "release-jobs" || name.start_with?("release-jobs/")) }
        tree["directories"].each_key do |name|
          next if excluded.call(name)
          FileUtils.mkdir_p(File.join(destination, name), mode: 0o700)
        end
        tree["files"].each do |name, row|
          next if excluded.call(name)
          target = File.join(destination, name)
          FileUtils.mkdir_p(File.dirname(target), mode: 0o700)
          copy_file(File.join(source, name), target, mode: row["mode"])
        end
        tree["directories"].sort_by { |name, _mode| -name.length }.each do |name, mode|
          next if excluded.call(name)
          File.chmod(mode, File.join(destination, name))
        end
      end
      def copy_file(source, destination, mode: 0o600)
        stat = File.lstat(source)
        raise Error, "snapshot_source" unless stat.file? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o022).zero?
        raise Error, "snapshot_destination_exists" if File.exist?(destination) || File.symlink?(destination)
        File.open(source, File::RDONLY | File::NOFOLLOW) do |input|
          File.open(destination, File::WRONLY | File::CREAT | File::EXCL, mode) do |output|
            IO.copy_stream(input, output)
            output.flush
            output.fsync
          end
        end
        raise Error, "snapshot_copy_mismatch" unless Digest::SHA256.file(source).hexdigest == Digest::SHA256.file(destination).hexdigest
      end
      private
      def relative_path!(value)
        raise Error, "snapshot_path" unless value.ascii_only? && value.bytesize.between?(1, 240) && value.match?(%r{\A[a-zA-Z0-9_.-]+(?:/[a-zA-Z0-9_.-]+)*\z}) &&
          value.split("/").none? { |part| %w[. ..].include?(part) }
      end
    end
  end
end
