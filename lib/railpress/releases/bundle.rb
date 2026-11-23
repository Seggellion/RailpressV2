# frozen_string_literal: true

require "stringio"
module Railpress
  module Releases
    module Bundle
      module_function
      def verify_tree!(directory, manifest)
        Filesystem.directory!(directory, private: true)
        expected = manifest.fetch("files")
        actual = Dir.glob(File.join(directory, "**", "*"), File::FNM_DOTMATCH).reject { |p| File.directory?(p) && !File.symlink?(p) }.map { |p| p.delete_prefix(directory + "/") }
        raise Invalid, "staging_inventory" unless (actual - [ ".complete" ]).sort == expected.keys.sort
        expected.each do |name, row|
          bytes = Filesystem.read(File.join(directory, name), maximum: row.fetch("bytes"))
          raise Invalid, "staged_digest" unless bytes.bytesize == row["bytes"] && Digest::SHA256.hexdigest(bytes) == row["sha256"]
          mode = File.stat(File.join(directory, name)).mode & 0o7777
          raise Invalid, "staged_permissions" unless mode == (row["mode"] == 0o755 ? 0o555 : 0o444)
        end
        runtime_hint = Filesystem.read(File.join(directory, ".ruby-version"), maximum: 80).strip
        raise Invalid, "incompatible_ruby_selector" unless runtime_hint == RUBY_VERSION
        product = Releases.parse(Filesystem.read(File.join(directory, "lib/railpress/product.json"), maximum: 4096), limit: 4096)
        Releases.keys!(product, %w[format version channel security_clock theme_api schema jobs configuration])
        raise Invalid, "product_compatibility" unless product["schema"] == Product::SCHEMA && product["jobs"] == Product::JOB_PAYLOAD && product["configuration"] == Product::CONFIGURATION
        lock = Filesystem.read(File.join(directory, "Gemfile.lock"), maximum: 8 * 1024 * 1024)
        locked_rails = lock[/^    rails \((\d+(?:\.\d+){1,3})\)$/, 1]
        raise Invalid, "locked_rails_incompatible" unless locked_rails && Manifest.requirement!(manifest["compatibility"]["rails"]).satisfied_by?(Gem::Version.new(locked_rails))
        raise Invalid, "product_identity" unless product["format"] == "railpress.product.v1" && product["version"] == manifest["version"] && product["channel"] == manifest["channel"] && product["security_clock"] == Product::SECURITY_CLOCK && product["theme_api"] == Product::THEME_API
        raise Invalid, "asset_manifest_identity" unless expected.fetch("public/assets/.manifest.json").fetch("sha256") == manifest.fetch("compatibility").fetch("assets_sha256")
        assets = Releases.parse(Filesystem.read(File.join(directory, "public/assets/.manifest.json"), maximum: 2 * 1024 * 1024), limit: 2 * 1024 * 1024)
        raise Invalid, "asset_manifest" unless assets.is_a?(Hash) && assets.length.between?(1, 4096)
        %w[admin.css admin_shell.js].each { |name| raise Invalid, "required_core_asset" unless assets.key?(name) }
        assets.each_value do |row|
          raise Invalid, "asset_entry" unless row.is_a?(Hash) && row["digested_path"].is_a?(String)
          name = "public/assets/#{row["digested_path"]}"
          Releases.path!(name)
          raise Invalid, "missing_asset" unless expected.key?(name)
        end
        true
      end
      def extract!(package, destination, manifest, capacity: Filesystem.method(:capacity!))
        bytes = Filesystem.read(package, maximum: Manifest::MAX_PACKAGE)
        expected = manifest.fetch("package")
        raise Invalid, "package_digest" unless bytes.bytesize == expected["bytes"] && Digest::SHA256.hexdigest(bytes) == expected["sha256"]
        parent = Filesystem.directory!(File.dirname(destination), private: true)
        raise Invalid, "staging_exists" if File.exist?(destination) || File.symlink?(destination)
        entries = Dir.children(parent)
        raise Invalid, "staging_quarantine_capacity" if entries.length >= 40 || entries.count { |name| name.start_with?("extract-") } >= 8
        capacity.call(parent, Manifest::MAX_EXPANDED * 2 + 8 * 1024**3)
        started = SecurityClock.elapsed
        inventory = manifest.fetch("files")
        seen = {}
        temporary = Dir.mktmpdir("extract-", parent)
        begin
          Tempfile.create([ "archive-", ".tar" ], parent) do |tar|
            tar.binmode
            size = 0
            Zlib::GzipReader.wrap(StringIO.new(bytes)) do |gzip|
              loop do
                chunk = gzip.read(65_536).to_s
                break if chunk.empty?
                size += chunk.bytesize
                raise Invalid, "archive_resource_limit" if size > Manifest::MAX_EXPANDED + 4096 * 1536 || SecurityClock.elapsed - started > 30
                tar.write(chunk)
              end
              raise Invalid, "archive_trailing_data" unless gzip.unused.to_s.empty?
            end
            tar.flush
            tar.rewind
            loop do
              raw = tar.read(512)
              raise Invalid, "truncated_archive" unless raw && raw.bytesize == 512
              if raw == "\0" * 512
                raise Invalid, "archive_terminator" unless tar.read(512) == "\0" * 512 && tar.read.to_s.bytes.all?(&:zero?)
                break
              end
              checksum = raw.bytes.each_with_index.sum { |byte, index| (148...156).cover?(index) ? 32 : byte }
              raise Invalid, "tar_checksum" unless raw[148, 8].match?(/\A[0-7]+\x00 ?\z/) && raw[148, 8].to_i(8) == checksum
              header = Gem::Package::TarHeader.from(StringIO.new(raw))
              name = header.prefix.empty? ? header.name : "#{header.prefix}/#{header.name}"
              Releases.path!(name)
              raise Invalid, "archive_entry_type" unless [ "0", "" ].include?(header.typeflag) && header.linkname.empty?
              raise Invalid, "duplicate_archive_path" if seen[name.downcase]
              seen[name.downcase] = true
              row = inventory.fetch(name) { raise Invalid, "undeclared_archive_file" }
              raise Invalid, "archive_permissions" unless header.mode == row["mode"] && header.uid.zero? && header.gid.zero?
              raise Invalid, "archive_size" unless header.size == row["bytes"]
              data = tar.read(header.size)
              raise Invalid, "archive_file_digest" unless data && data.bytesize == header.size && Digest::SHA256.hexdigest(data) == row["sha256"]
              padding = tar.read((512 - header.size % 512) % 512)
              raise Invalid, "archive_padding" unless padding && padding.bytes.all?(&:zero?)
              target = File.join(temporary, name)
              FileUtils.mkdir_p(File.dirname(target), mode: 0o700)
              immutable_mode = row["mode"] == 0o755 ? 0o555 : 0o444
              File.open(target, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, immutable_mode) do |file|
                file.binmode
                file.write(data)
                file.flush
                file.chmod(immutable_mode)
                file.fsync
              end
              raise Invalid, "archive_resource_limit" if SecurityClock.elapsed - started > 30
            end
          end
          raise Invalid, "missing_archive_file" unless seen.keys.sort == inventory.keys.map(&:downcase).sort
          verify_tree!(temporary, manifest)
          Filesystem.atomic(File.join(temporary, ".complete"), Digest::SHA256.hexdigest(Releases.canonical(manifest)), mode: 0o400)
          File.rename(temporary, destination)
          File.open(parent, File::RDONLY) { |dir| dir.fsync }
          destination
        ensure
          # Retain bounded interrupted artifacts for operator review, never touch active/shared files.
          File.write(File.join(temporary, ".interrupted"), "Not an active release\n") if File.directory?(temporary)
        end
      rescue Zlib::Error, Gem::Package::TarInvalidError, EOFError, ArgumentError
        raise Invalid, "malformed_archive"
      end
    end
  end
end
