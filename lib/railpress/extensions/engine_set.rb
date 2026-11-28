# frozen_string_literal: true

module Railpress
  module Extensions
    class EngineSet
      FORMAT = "railpress.extension-lock.v1"
      EMPTY_FINGERPRINT = Extensions.digest({ "format" => FORMAT, "packages" => [] }).freeze
      Entry = Data.define(:manifest, :root, :package_sha256) do
        def id = manifest.id
        def version = manifest.version
        def entrypoint = File.join(root, manifest.entrypoint)
        def plan_sha256 = Extensions.digest(manifest.migrations)
      end

      # Operators own the entire real path. Only guarded test boots can use a
      # same-UID fixture; the production web process must be read-only here.
      class Store
        attr_reader :root

        def initialize(root, synthetic:)
          raise Invalid, "extension_store_path" unless root.is_a?(String) && root.start_with?("/") && File.expand_path(root) == root
          raise Invalid, "extension_service_must_be_unprivileged" if !synthetic && Process.uid.zero?
          @synthetic = synthetic
          @root = root
          directory!(root)
        end

        def directory!(path)
          current = "/"
          path.split("/").reject(&:empty?).each do |segment|
            current = File.join(current, segment)
            stat = File.lstat(current)
            raise Invalid, "extension_store_directory" unless stat.directory? && !stat.symlink? && owned?(current, stat)
          end
          path
        rescue SystemCallError
          raise Invalid, "extension_store_directory", cause: nil
        end

        def read(path, limit:, mode: nil)
          directory!(File.dirname(path))
          before = File.lstat(path)
          raise Invalid, "extension_store_file" unless before.file? && !before.symlink? && owned?(path, before) && before.size <= limit
          raise Invalid, "extension_inventory_mode" if mode && (before.mode & 0o7777) != mode
          File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
            current = file.stat
            raise Invalid, "extension_store_changed" unless current.ino == before.ino && current.dev == before.dev
            bytes = file.read(limit + 1).to_s
            raise Invalid, "extension_store_size" unless bytes.bytesize == before.size && bytes.bytesize <= limit
            bytes
          end
        rescue SystemCallError
          raise Invalid, "extension_store_file", cause: nil
        end

        def inventory!(root, files)
          found = []
          pending = [ "" ]
          until pending.empty?
            relative = pending.pop
            directory = directory!(File.join(root, relative).delete_suffix("/"))
            Dir.each_child(directory) do |name|
              path = relative.empty? ? name : File.join(relative, name)
              Releases.path!(path)
              stat = File.lstat(File.join(root, path))
              if stat.directory? && !stat.symlink? && files.keys.any? { |key| key.start_with?("#{path}/") }
                pending << path
              elsif stat.file? && files.key?(path)
                found << path
              else
                raise Invalid, "extension_inventory_extra"
              end
            end
          end
          raise Invalid, "extension_inventory_missing" unless found.sort == files.keys.sort
          files.each do |path, entry|
            bytes = read(File.join(root, path), limit: entry["size"], mode: Integer(entry["mode"], 8))
            raise Invalid, "extension_inventory_hash" unless bytes.bytesize == entry["size"] && Digest::SHA256.hexdigest(bytes) == entry["sha256"]
          end
        rescue SystemCallError
          raise Invalid, "extension_inventory_unavailable", cause: nil
        end

        private

        def owned?(path, stat)
          return false unless (stat.mode & 0o7022).zero?
          @synthetic ? [ 0, Process.uid ].include?(stat.uid) : stat.uid.zero? && !File.writable?(path)
        end
      end

      attr_reader :entries, :generation, :previous_generation, :previous_fingerprint, :site, :fingerprint, :trust, :core_anchor

      def self.load(root:, site:, synthetic: false, core_anchor: Product::VERSION, runtime_core: Product::VERSION)
        store = Store.new(root, synthetic: synthetic)
        document = Releases.parse(store.read(File.join(root, "engine-set.json"), limit: 64 * 1024), limit: 64 * 1024)
        trust = Trust.new(store.read(File.join(root, "trust.json"), limit: Trust::LIMIT))
        new(document, trust: trust, store: store, expected_site: site, core_anchor: core_anchor, runtime_core: runtime_core, synthetic_genesis: synthetic)
      end

      def initialize(document, trust:, store:, expected_site:, core_anchor: Product::VERSION, runtime_core: Product::VERSION, synthetic_genesis: false)
        Releases.keys!(document, %w[format site core extension_api generation previous_generation previous_fingerprint packages])
        Extensions.uuid!(document["site"])
        raise Invalid, "extension_lock_identity" unless document["format"] == FORMAT && document["site"] == expected_site &&
          document["core"] == core_anchor && document["extension_api"] == Product::EXTENSION_API
        @runtime_core = Extensions.version!(runtime_core).dup.freeze
        @core_anchor = document["core"].freeze
        @site = document["site"].freeze
        @generation = Extensions.generation!(document["generation"], minimum: synthetic_genesis ? 0 : 1)
        @previous_generation = Extensions.generation!(document["previous_generation"])
        @previous_fingerprint = Releases.identity!(document["previous_fingerprint"]).freeze
        rows = document["packages"]
        raise Invalid, "extension_lock_inventory" unless rows.is_a?(Array) && rows.length <= 16
        if generation.zero?
          unless previous_generation.zero? && previous_fingerprint == EMPTY_FINGERPRINT && rows.empty?
            raise Invalid, "extension_lock_generation"
          end
          @fingerprint = EMPTY_FINGERPRINT
        else
          raise Invalid, "extension_lock_generation" unless previous_generation == generation - 1 &&
            (previous_generation.positive? || previous_fingerprint == EMPTY_FINGERPRINT)
          @fingerprint = Extensions.digest(document).freeze
        end
        @trust = trust
        @store = store.freeze
        @entries = {}
        rows.each { |row| load_entry!(row, store) }
        @entries.freeze
        freeze
      end

      def retained_entry!(id:, version:, archive:, digest:)
        artifact!({ "id" => id, "version" => version, "package_sha256" => archive, "manifest_sha256" => digest }, @store)
      end

      def review_staged_entry!(row)
        current = Trust.new(@store.read(File.join(@store.root, "trust.json"), limit: Trust::LIMIT))
        artifact!(row, @store, authority: current)
      end

      def staged_catalog(id, now: Time.now.to_i)
        directory = File.join(@store.root, "catalogs", Extensions.id!(id))
        bytes = @store.read(File.join(directory, "catalog.json"), limit: Catalog::LIMIT)
        policy = Trust.new(@store.read(File.join(directory, "trust.json"), limit: Trust::LIMIT))
        pin = Releases.parse(@store.read(File.join(directory, "pin.json"), limit: 1024), limit: 1024)
        Catalog.new(bytes, trust: policy, pin: pin, id: id, now: now)
      rescue Invalid => error
        raise unless %w[extension_store_file extension_store_directory].include?(error.message)
        raise Invalid, "module_catalog_offline", cause: nil
      end

      private

      def load_entry!(row, store)
        Releases.keys!(row, %w[id version package_sha256 manifest_sha256 entrypoint dependencies])
        id = row["id"]
        raise Invalid, "extension_duplicate_package" if entries.key?(id)
        entry = artifact!(row, store)
        resolved = entry.manifest.dependencies.to_h do |name, range|
          dependency = entries[name]
          raise Invalid, "extension_dependency_order_or_version" unless dependency && Manifest.includes_version?(range, dependency.version)
          [ name, dependency.version ]
        end
        raise Invalid, "extension_dependency_lock" unless row["dependencies"] == resolved
        entries[id.freeze] = entry
      end

      def artifact!(row, store, authority: trust)
        id = Extensions.id!(row["id"])
        version = Extensions.version!(row["version"])
        package_sha = Releases.identity!(row["package_sha256"])
        package = File.join(store.root, "packages", id, version, package_sha)
        manifest = Manifest.new(store.read(File.join(package, "manifest.json"), limit: Manifest::LIMIT))
        unless manifest.id == id && manifest.version == version && manifest.digest == row["manifest_sha256"] &&
            manifest.entrypoint == row.fetch("entrypoint", manifest.entrypoint) && manifest.compatible?(core: @runtime_core)
          raise Invalid, "extension_package_identity"
        end
        verify_release!(row, store, package, authority)
        files_root = File.join(package, "files")
        store.inventory!(files_root, manifest.files)
        Entry.new(manifest, files_root.freeze, package_sha.freeze)
      end

      def verify_release!(row, store, package, authority)
        bytes = store.read(File.join(package, "envelope.json"), limit: Trust::LIMIT)
        statement = authority.verify!(bytes, purpose: Trust::PACKAGE)
        Releases.keys!(statement, %w[format id version manifest_sha256 package_sha256 size sequence expires_at])
        %w[id version manifest_sha256 package_sha256].each do |key|
          raise Invalid, "extension_envelope_identity" unless statement[key] == row[key]
        end
        size = statement["size"]
        Releases.integer!(size, 1, Manifest::PACKAGE_LIMIT)
        archive = store.read(File.join(package, "package.tar.gz"), limit: size)
        raise Invalid, "extension_archive_hash" unless archive.bytesize == size && Digest::SHA256.hexdigest(archive) == row["package_sha256"]
      end
    end
  end
end
