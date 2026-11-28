# frozen_string_literal: true

module Railpress
  module Recovery
    class Target
      attr_reader :root, :data, :registry_root, :profile
      def initialize(registry_root:, profile:, engine:, root:, db_tools:, install_id:)
        disk = %w[w03_bridge w03_restore w03_reference w03_restore_retry].include?(profile)
        raise Error, "fresh_profile" unless disk || %w[gcs_source gcs_good gcs_bad gcs_focus gcs_full gcs_r1_target gcs_r2_target].include?(profile)
        @registry_root = File.realpath(registry_root)
        @profile = profile
        @root = F.directory!(root, private: true)
        @scope = @registry_root + (disk ? "/.local/state/w03/" : "/.local/state/gcs-recovery/")
        raise Error, "fresh_root_scope" unless @root.start_with?(@scope)
        NativeHost.uuid!(install_id)
        @data = { "engine" => engine, "db_tools" => db_tools, "install_id" => install_id }
        Releases.keys!(db_tools, %w[dump restore client])
        db_tools.each_value do |path|
          stat = File.lstat(path)
          raise Error, "native_executable" unless path == File.absolute_path(path) && stat.file? && File.executable?(path) && (stat.mode & 0o022).zero?
        end
        %w[run logs].each do |name|
          directory = path(name)
          Dir.mkdir(directory, 0o700) unless File.exist?(directory)
          F.directory!(directory, private: true)
        end
        database!
      end
      def path(*parts) = File.join(root, *parts)
      def database!
        target = TestDatabase.load!(root: registry_root, engine: data["engine"], profile: profile,
          environment: "test", confirmed: "railpress-synthetic-only")
        [ target, TestDatabase.verify!(target, environment: "test", confirmed: "railpress-synthetic-only") ]
      end
      def database = NativeHost::Database.new(self)
      def lock!
        # Canonical DB/profile lock, independent of caller-selected receipt root.
        directory = File.join(@scope, "locks")
        Dir.mkdir(directory, 0o700) unless File.exist?(directory)
        F.directory!(directory, private: true)
        lock = File.open(File.join(directory, "#{data['engine']}-#{profile}.lock"), File::RDWR | File::CREAT | File::NOFOLLOW, 0o600)
        raise Error, "fresh_lock_unsafe" unless lock.stat.uid == Process.uid && (lock.stat.mode & 0o077).zero?
        raise Error, "fresh_operation_busy" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        lock
      rescue StandardError
        lock&.close
        raise
      end
      def empty!
        self.class.assert_empty!(database, data["engine"])
      end
      def self.assert_empty!(db, engine)
        db.assert_restore_offline!
        raise Error, "fresh_target_populated" unless db.table_names.empty?
        scope = engine == "postgresql" ? "table_schema='public'" : "table_schema=DATABASE()"
        raise Error, "fresh_target_objects" unless db.query("SELECT table_name FROM information_schema.views WHERE #{scope}").empty?
        scope = engine == "postgresql" ? "routine_schema='public'" : "routine_schema=DATABASE()"
        raise Error, "fresh_target_objects" unless db.query("SELECT routine_name FROM information_schema.routines WHERE #{scope}").empty?
        true
      end
    end
  end
end
