# frozen_string_literal: true

module Railpress
  module Recovery
    class Disk
      ADMISSION = "railpress.disk-promotion-evidence.v1"
      FORMAT = "railpress.disk-backup.v1"
      ROOTS = %w[engines media themes].freeze
      LIMIT = NativeHost::Snapshot::LIMIT
      MAX_INDEX = 8 * 1024 * 1024
      TAG = 16
      IV = 12

      def initialize(root:, key:, signer:, quota: LIMIT)
        @root = F.directory!(root, private: true)
        raise Error, "disk_encryption_key" unless key.is_a?(String) && key.bytesize == 32
        raise Error, "disk_quota" unless quota.is_a?(Integer) && quota.between?(1, LIMIT)
        @key, @signer, @quota = key.b.freeze, signer, quota
        @inventory = NativeHost::Snapshot.new(nil, signer: signer)
      end

      def self.pin(path)
        path = F.directory!(path, private: true)
        stat = File.stat(path)
        { "path" => path, "device" => stat.dev, "inode" => stat.ino, "uid" => stat.uid, "mode" => stat.mode & 0o777 }
      end

      def inventory!(pins)
        Releases.keys!(pins, ROOTS)
        pins.to_h do |name, pin|
          raise Error, "disk_mount_identity" unless pin == self.class.pin(pin.fetch("path"))
          raise Error, "disk_root_overlap" if pins.except(name).values.any? { |other| pin["path"].start_with?(other["path"] + "/") || pin["path"] == other["path"] }
          [ name, @inventory.inventory(pin.fetch("path")) ]
        end
      rescue SystemCallError, KeyError, TypeError
        raise Error, "disk_mount_identity", cause: nil
      end

      def capture!(source:, pins:, packages:, release:, contract:, checkpoint:, confirmation:)
        raise Error, "disk_capture_fence" unless confirmation == "writers-stopped-no-ddl"
        Releases.identity!(release)
        Releases.integer!(checkpoint, 0, 2**53 - 1)
        Releases::PackageContext.verify!(packages)
        raise Error, "fresh_profile" unless source.profile == "w03_bridge"
        config = NativeHost::Config.new(source.root)
        raise Error, "disk_source_binding" unless config.data["test_database_profile"] == source.profile &&
          config.data.values_at("install_id", "engine") == source.data.values_at("install_id", "engine")
        expected_pins = ROOTS.to_h { |name| [ name, self.class.pin(source.path("shared", name)) ] }
        raise Error, "disk_mount_identity" unless pins == expected_pins
        database = source.database
        identity = source.database!.last
        raise Error, "disk_source_binding" unless config.database!.last == identity
        database.assert_installation!
        database.assert_restore_offline!
        raise Error, "disk_site" unless packages["site"] == source.data["install_id"]
        extra = module_tables(database, packages)
        integrity = database.integrity(extra_tables: extra)
        evidence = integrity.capture
        trees = inventory!(pins)
        inventory_bytes = trees.values.sum { |tree| tree.fetch("files").values.sum { |row| row.fetch("bytes") } }
        reserve!(@root, inventory_bytes, trees.values.sum { |tree| tree["files"].size + tree["directories"].size })
        verify_disk_refs!(database, pins.fetch("media").fetch("path"))
        id = SecureRandom.uuid
        partial = File.join(@root, "#{id}.partial")
        Dir.mkdir(partial, 0o700)
        Dir.mktmpdir(".native-dump-", partial) do |staging|
          dump = File.join(staging, "database.dump")
          database.dump!(id, dump)
          database.assert_restore_offline!
          integrity.verify!(evidence)
          raise Error, "disk_capture_changed" unless inventory!(pins) == trees
          dump_record = file_record(dump)
          raise Error, "disk_quota" if inventory_bytes + dump_record["bytes"] > @quota
          files = { "database.dump" => dump_record }
          trees.each do |name, tree|
            tree["files"].each { |file, row| files["#{name}/#{file}"] = row }
          end
          files.each do |relative, row|
            source_path = relative == "database.dump" ? dump : File.join(pins.fetch(relative.split("/").first).fetch("path"), relative.split("/", 2).last)
            raise Error, "disk_capture_changed" unless file_record(source_path) == row
            seal(source_path, box(partial, relative), aad(id, relative, row))
          end
          database.assert_restore_offline!
          integrity.verify!(evidence)
          raise Error, "disk_capture_changed" unless inventory!(pins) == trees
          statement = { "format" => FORMAT, "id" => id, "site" => packages["site"], "release" => release, "database" => identity,
            "database_integrity" => evidence, "extra_tables" => extra, "packages" => packages, "contract" => contract,
            "deployment" => config.data["deployment_id"], "environment" => config.data["environment_sha256"],
            "checkpoint" => checkpoint, "files" => files, "directories" => trees.transform_values { |tree| tree["directories"] },
            "boot_domain" => SecurityClock.boot_domain, "captured_elapsed" => SecurityClock.elapsed }
          manifest = File.join(staging, "index.json")
          bytes = Releases.canonical(NativeHost.sign(statement, @signer))
          raise Error, "disk_index_size" if bytes.bytesize > MAX_INDEX
          F.atomic(manifest, bytes)
          seal(manifest, box(partial, "index"), id)
        end
        File.rename(partial, File.join(@root, id))
        File.open(@root, File::RDONLY, &:fsync)
        id
      end

      def restore!(id:, source:, target:, expected_release:, ledger_key:, ledger_bytes:, observed_head:)
        NativeHost.uuid!(id)
        Releases.identity!(expected_release)
        raise Error, "fresh_profile" unless source.profile == "w03_bridge" && %w[w03_restore w03_restore_retry].include?(target.profile)
        lock = target.lock!
        path = target.path("run", "disk-recovery.json")
        raise Error, "fresh_operation_exists" if File.exist?(path) || File.symlink?(path)
        config = NativeHost::Config.new(source.root)
        original = source.database!.last
        fresh = target.database!.last
        if original["database"] == fresh["database"] || original["username"] == fresh["username"] ||
            source.root == target.root || target.root.start_with?(source.root + "/") || source.root.start_with?(target.root + "/")
          raise Error, "fresh_same_target"
        end
        source_db, target_db = source.database, target.database
        source_db.assert_installation!
        source_db.assert_restore_offline!
        target.empty!
        receipt = { "format" => "railpress.disk-restore.v1", "state" => "VERIFYING", "snapshot" => id,
          "workers" => "STOPPED", "promotion" => "HELD", "started" => SecurityClock.elapsed }
        checkpoint!(path, receipt)
        destination = target.path("disk")
        raise Error, "fresh_disk_exists" if File.exist?(destination) || File.symlink?(destination)
        Dir.mkdir(destination, 0o700)
        encrypted = F.directory!(File.join(@root, id), private: true)
        statement = unseal_inventory(id, encrypted, destination)
        unless statement.values_at("id", "release", "database", "site") == [ id, expected_release, original, target.data["install_id"] ] &&
            source.data.values_at("install_id", "engine") == target.data.values_at("install_id", "engine") &&
            config.data["test_database_profile"] == source.profile && config.database!.last == original &&
            statement.values_at("deployment", "environment") == config.data.values_at("deployment_id", "environment_sha256")
          raise Error, "disk_restore_binding"
        end
        extra = module_tables_from_names(statement["extra_tables"], statement["packages"])
        candidate_modules = verify_engine_set!(destination, statement)
        verify_themes!(destination, statement)
        source_integrity = source_db.integrity(extra_tables: extra)
        prior = source_integrity.capture
        Fresh.authority_unchanged!(prior, statement["database_integrity"])
        target.empty!
        receipt["state"] = "REPLAY_SQL"
        checkpoint!(path, receipt)
        dump = File.join(destination, "database.dump")
        target_db.restore_fresh!(SecureRandom.uuid, dump, expected_tables: statement["database_integrity"]["schema"]["tables"], extra_tables: extra)
        target_db.integrity(extra_tables: extra).verify!(statement["database_integrity"])
        verify_disk_refs!(target_db, File.join(destination, "media"))
        ledger = restore_ledger(ledger_bytes, ledger_key, statement, observed_head, candidate_modules)
        receipt["ledger"] = "HELD"
        revoke_credentials!(target_db)
        Revocations.reconcile!(target_db, withdrawn: ledger&.modules, site: statement["site"], candidates: ledger&.candidates || [])
        if ledger
          receipt.merge!("ledger" => "RECONCILED", "ledger_sha256" => Digest::SHA256.hexdigest(ledger_bytes),
            "candidate_withdrawals" => ledger.candidates.length)
        end
        rotate_clock!(target, statement["site"])
        target_db.assert_restore_offline!
        source_db.assert_restore_offline!
        source_integrity.verify!(prior)
        File.unlink(dump)
        receipt.merge!("state" => "RESTORED_PRIVATE", "byte_and_reference_integrity" => true, "source_unchanged" => true,
          "credentials_revoked" => true, "clock_held" => true, "completed" => SecurityClock.elapsed, "withdrawn" => ledger&.modules || [])
        checkpoint!(path, receipt)
        attest_promotion!(config, statement, receipt) if ledger
        receipt
      rescue StandardError => error
        if receipt
          receipt["state"] = "QUARANTINED"
          receipt["error"] = error.is_a?(Error) && error.message.match?(/\A[a-z_]{1,80}\z/) ? error.message : "disk_restore_failed"
          checkpoint!(path, receipt)
        end
        raise
      ensure
        lock&.close
      end

      def self.admit_promotion!(config:, release:, packages:, policy:, trust_state:)
        raise Error, "disk_promotion_required" unless config.data["test_database_profile"] == "w03_bridge"
        path = config.path("run", "disk-promotion.json")
        envelope = NativeHost.load_document(path, maximum: 16_384)
        Releases.keys!(envelope, %w[statement signature])
        proof = envelope.fetch("statement")
        Releases.keys!(proof, %w[format deployment environment site release packages snapshot domain captured restored])
        policy.verify!(Releases.canonical(proof), envelope["signature"], trust_state, purpose: "status")
        NativeHost.uuid!(proof["snapshot"])
        expected = [ ADMISSION, *config.data.values_at("deployment_id", "environment_sha256", "install_id"),
          release, Recovery.digest(packages), SecurityClock.boot_domain ]
        unless proof.values_at("format", "deployment", "environment", "site", "release", "packages", "domain") == expected &&
            proof.values_at("captured", "restored").all? { |elapsed| elapsed.is_a?(Numeric) && elapsed.finite? } &&
            proof["captured"] <= proof["restored"] &&
            (SecurityClock.elapsed - proof["captured"]).between?(0, config.data["max_snapshot_age_seconds"])
          raise Error, "disk_promotion_binding"
        end
        proof
      rescue Error => error
        raise unless error.message == "file_unavailable"
        raise Error, "disk_promotion_required", cause: nil
      end

      private

      def attest_promotion!(config, statement, receipt)
        proof = { "format" => ADMISSION, "deployment" => statement["deployment"], "environment" => statement["environment"],
          "site" => statement["site"], "release" => statement["release"], "packages" => Recovery.digest(statement["packages"]),
          "snapshot" => statement["id"], "domain" => statement["boot_domain"], "captured" => statement["captured_elapsed"],
          "restored" => receipt["completed"] }
        checkpoint!(config.path("run", "disk-promotion.json"), proof)
      end

      def reserve!(path, bytes, entries)
        raise Error, "disk_quota" unless bytes <= @quota
        F.capacity!(path, bytes * 2 + 64 * 1024**2)
        output, result = Open3.capture2("df", "-Pi", "--", path)
        fields = output.lines.last.to_s.split
        raise Error, "disk_inode_reserve" unless result.success? && fields[3]&.match?(/\A[0-9]+\z/) && Integer(fields[3]) >= entries + 128
      rescue Errno::ENOSPC, Errno::EDQUOT
        raise Error, "disk_capacity", cause: nil
      end

      def checkpoint!(path, receipt)
        F.atomic(path, Releases.canonical(NativeHost.sign(receipt, @signer)))
      end

      def module_tables(database, packages)
        module_tables_from_names(database.table_names.grep(/\Arp_ext_/), packages)
      end

      def module_tables_from_names(names, packages)
        Releases::PackageContext.verify!(packages)
        prefixes = packages.fetch("modules").map { |row| "rp_ext_#{row.fetch('id').tr('-', '_')}_" }
        unless names.is_a?(Array) && names.length <= 24 && names == names.uniq.sort &&
            names.all? { |name| name.match?(/\A[a-z0-9_]{1,62}\z/) && prefixes.any? { |prefix| name.start_with?(prefix) } }
          raise Error, "disk_module_tables"
        end
        names
      end

      def file_record(path)
        stat = File.lstat(path)
        raise Error, "disk_file_identity" unless stat.file? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o022).zero?
        { "sha256" => Recovery.sha(path), "bytes" => stat.size, "mode" => stat.mode & 0o777 }
      end

      def verify_disk_refs!(database, root)
        key = database.quote_identifier("key")
        blobs = database.query("SELECT id,#{key},byte_size,service_name FROM active_storage_blobs ORDER BY id LIMIT 1001")
        raise Error, "disk_reference_limit" if blobs.length > 1000
        paths = blobs.to_h do |row|
          value = row["key"]
          unless value&.match?(/\A[a-zA-Z0-9_-]{4,255}\z/) && %w[local test].include?(row["service_name"])
            raise Error, "disk_blob_identity"
          end
          path = File.join(root, value[0, 2], value[2, 2], value)
          record = file_record(path)
          raise Error, "disk_blob_size" unless record["bytes"] == Integer(row["byte_size"])
          [ Integer(row["id"]), record["sha256"] ]
        end
        database.query("SELECT blob_id,thumbnail_blob_id,sha256,thumbnail_sha256 FROM media_assets ORDER BY id LIMIT 1001").each do |row|
          { "blob_id" => "sha256", "thumbnail_blob_id" => "thumbnail_sha256" }.each do |reference, checksum|
            next if row[reference].nil?
            raise Error, "disk_media_checksum" unless paths[Integer(row[reference])] == row[checksum]
          end
        end
      rescue SystemCallError, ArgumentError
        raise Error, "disk_blob_unavailable", cause: nil
      end

      def box(base, path) = File.join(base, Digest::SHA256.hexdigest(path) + ".box")
      def aad(id, path, row) = Releases.canonical([ id, path, row ])

      def seal(source, destination, data)
        cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
        cipher.key = @key
        nonce = cipher.random_iv
        cipher.auth_data = data
        File.open(source, File::RDONLY | File::NOFOLLOW) do |input|
          input.binmode
          File.open(destination, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |output|
            output.binmode
            output.write(nonce)
            until input.eof?
              output.write(cipher.update(input.read(65_536)))
            end
            output.write(cipher.final, cipher.auth_tag(TAG))
            output.flush
            output.fsync
          end
        end
      end

      def open_box(source, destination, data, maximum:)
        cipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
        cipher.key = @key
        File.open(source, File::RDONLY | File::NOFOLLOW) do |input|
          input.binmode
          stat = input.stat
          size = stat.size - IV - TAG
          unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero? && size.between?(0, maximum)
            raise Error, "disk_ciphertext_inventory"
          end
          cipher.iv = input.read(IV)
          input.seek(-TAG, IO::SEEK_END)
          cipher.auth_tag = input.read(TAG)
          cipher.auth_data = data
          input.seek(IV)
          Tempfile.create([ ".disk-authenticated-", ".tmp" ], File.dirname(destination), binmode: true) do |output|
            while size.positive?
              chunk = input.read([ size, 65_536 ].min)
              raise Error, "disk_ciphertext_inventory" unless chunk && !chunk.empty?
              size -= chunk.bytesize
              output.write(cipher.update(chunk))
            end
            output.write(cipher.final)
            output.flush
            output.fsync
            File.link(output.path, destination)
          end
        end
      rescue OpenSSL::Cipher::CipherError, SystemCallError
        raise Error, "disk_authentication", cause: nil
      end

      def unseal_inventory(id, encrypted, destination)
        index = File.join(destination, "index.json")
        open_box(box(encrypted, "index"), index, id, maximum: MAX_INDEX)
        envelope = NativeHost.load_document(index, maximum: MAX_INDEX)
        Releases.keys!(envelope, %w[statement signature])
        statement = envelope.fetch("statement")
        key_id = Releases.key_id(@signer)
        Releases.signature!(Releases.canonical(statement), envelope["signature"],
          { key_id => { "purpose" => "status", "public_key" => @signer.public_to_pem } }, purpose: "status")
        Releases.keys!(statement, %w[format id site release database database_integrity extra_tables packages contract deployment environment checkpoint files directories boot_domain captured_elapsed])
        raise Error, "disk_format" unless statement["format"] == FORMAT && statement["id"] == id
        File.unlink(index)
        files = statement.fetch("files")
        folders = statement.fetch("directories")
        Releases.keys!(folders, ROOTS)
        raise Error, "disk_file_inventory" unless files.is_a?(Hash) && files.size.between?(1, 5001) && files.key?("database.dump")
        files.each do |relative, row|
          safe_path!(relative) unless relative == "database.dump"
          Releases.keys!(row, %w[sha256 bytes mode])
          Releases.identity!(row["sha256"])
          Releases.integer!(row["bytes"], 0, LIMIT)
          Releases.integer!(row["mode"], 0, 0o777)
          raise Error, "disk_file_mode" unless (row["mode"] & 0o022).zero?
        end
        reserve!(destination, files.values.sum { |row| row["bytes"] }, files.size + folders.values.sum(&:size))
        expected = [ "index", *files.keys ].map { |name| File.basename(box(encrypted, name)) }
        raise Error, "disk_ciphertext_inventory" unless Dir.children(encrypted).sort == expected.sort
        folders.each do |name, entries|
          Dir.mkdir(File.join(destination, name), 0o700)
          entries.each do |relative, mode|
            safe_path!("#{name}/#{relative}")
            Releases.integer!(mode, 0, 0o777)
            raise Error, "disk_file_mode" unless (mode & 0o022).zero?
            FileUtils.mkdir_p(File.join(destination, name, relative), mode: 0o700)
          end
        end
        files.each do |relative, row|
          path = File.join(destination, relative)
          open_box(box(encrypted, relative), path, aad(id, relative, row), maximum: row["bytes"])
          File.chmod(row["mode"], path)
          raise Error, "disk_plaintext_inventory" unless file_record(path) == row
        end
        folders.each do |name, entries|
          entries.sort_by { |relative, _| -relative.length }.each { |relative, mode| File.chmod(mode, File.join(destination, name, relative)) }
        end
        statement
      rescue KeyError, TypeError, ArgumentError
        raise Error, "disk_manifest", cause: nil
      end

      def safe_path!(relative)
        unless relative.is_a?(String) && relative.bytesize <= 255 && relative.match?(%r{\A(?:engines|media|themes)/[a-zA-Z0-9_.-]+(?:/[a-zA-Z0-9_.-]+)*\z}) &&
            relative.split("/").none? { |part| %w[. ..].include?(part) }
          raise Error, "disk_path"
        end
      end

      def restore_ledger(bytes, key, statement, observed_head, candidate_modules)
        return unless bytes && key
        packages = statement.fetch("packages")
        Revocations.verify_restore!(bytes, key: key, site: statement["site"], checkpoint: statement["checkpoint"],
          observed_head: observed_head, now: Time.now.to_i, snapshot: statement["id"], packages: Recovery.digest(packages),
          package_ids: packages.fetch("modules").map { |row| row.fetch("id") }, candidate_modules: candidate_modules)
      rescue Error
        nil
      end

      def verify_engine_set!(destination, statement)
        config = statement["packages"]
        return [] if config["modules"].empty? && config["generation"].zero?
        set = Extensions::EngineSet.load(root: File.join(destination, "engines"), site: statement["site"], synthetic: true,
          core_anchor: config["anchor"], runtime_core: config["core"])
        raise Error, "restored_engine_fingerprint" unless set.fingerprint == config["fingerprint"] && set.generation == config["generation"]
        config["modules"].filter_map do |row|
          entry = if row["presence"] == "installed"
            set.entries[row["id"]]
          else
            set.retained_entry!(id: row["id"], version: row["version"], archive: row["package"], digest: row["manifest"])
          end
          raise Error, "restored_module_identity" unless entry && [ entry.version, entry.package_sha256, entry.manifest.digest ] ==
            row.values_at("version", "package", "manifest")
          row["id"] if Extensions::CandidateWithdrawals.supports?(entry.manifest)
        end
      end

      def verify_themes!(destination, statement)
        themes = statement.fetch("packages").fetch("themes")
        return if themes.empty?
        root = File.join(destination, "themes")
        keys = ThemePackage.parse(F.read(File.join(root, "trusted-keys.json"), maximum: 65_536))
        themes.each do |row|
          ThemePackage.identity!(*row.values_at("id", "version", "digest"))
          path = File.join(root, "packages", *row.values_at("id", "version", "digest"))
          bundle = ThemePackage.load(path, trusted_keys: keys, runtime_core: statement.fetch("packages").fetch("core"))
          unless bundle.digest == row["digest"] && bundle.manifest.values_at("id", "version", "schema_version") == row.values_at("id", "version", "schema")
            raise Error, "restored_theme_identity"
          end
        end
      rescue ThemePackage::Invalid
        raise Error, "restored_theme_identity", cause: nil
      end

      def revoke_credentials!(database)
        database.revoke_restored_credentials!
        Fresh::MEMBER_EPHEMERAL.each { |name| database.execute("DELETE FROM #{database.quote_identifier(name)}") }
        database.execute("UPDATE members SET auth_version=auth_version+1")
      end

      def rotate_clock!(target, site)
        root = target.path("candidate-private")
        Dir.mkdir(root, 0o700)
        F.atomic(File.join(root, "setup.json"), Releases.canonical({ "version" => 1, "status" => "installed", "install_id" => site }))
        raise Error, "fresh_clock_not_held" unless SecurityClock.new(root).sample.fetch("anomaly")
      end
    end
  end
end
