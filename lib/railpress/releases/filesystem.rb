# frozen_string_literal: true

module Railpress
  module Releases
    module Filesystem
      module_function
      def directory!(path, private: false)
        raise Invalid, "absolute_directory_required" unless path.is_a?(String) && path.start_with?("/") && File.expand_path(path) == path
        current = "/"
        path.split("/").reject(&:empty?).each do |part|
          current = File.join(current, part)
          stat = File.lstat(current)
          raise Invalid, "unsafe_ancestor" unless stat.directory? && !stat.symlink?
        end
        stat = File.stat(path)
        raise Invalid, "private_operator_root" if private && (stat.uid != Process.uid || (stat.mode & 0o077) != 0)
        path
      rescue SystemCallError
        raise Invalid, "directory_unavailable"
      end
      def read(path, maximum:)
        stat = File.lstat(path)
        raise Invalid, "unsafe_file" unless stat.file? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o022).zero? && stat.size <= maximum
        File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
          raise Invalid, "changed_file" unless file.stat.ino == stat.ino && file.stat.dev == stat.dev
          bytes = file.read(maximum + 1).to_s
          raise Invalid, "file_limit" if bytes.bytesize > maximum
          bytes
        end
      rescue SystemCallError
        raise Invalid, "file_unavailable"
      end
      def atomic(path, bytes, mode: 0o600)
        raise Invalid, "unsafe_destination" if File.symlink?(path)
        Tempfile.create([ "release-", ".tmp" ], File.dirname(path)) do |file|
          file.chmod(mode)
          file.binmode
          file.write(bytes)
          file.flush
          file.fsync
          File.rename(file.path, path)
        end
        File.open(File.dirname(path), File::RDONLY) { |dir| dir.fsync }
      end
      def capacity!(path, required)
        # Argument vector only; no shell and no manifest-controlled command/path.
        require "open3"
        output, status = Open3.capture2("df", "-PB1", "--", path)
        raise Invalid, "capacity_unknown" unless status.success?
        available = Integer(output.lines.last.split[3], 10)
        raise Invalid, "disk_capacity" if available < required
        if File.exist?("/mnt/c")
          output, status = Open3.capture2("df", "-PB1", "--", "/mnt/c")
          raise Invalid, "host_capacity_unknown" unless status.success?
          raise Invalid, "host_disk_capacity" if Integer(output.lines.last.split[3], 10) < 8 * 1024**3
        end
        available
      rescue ArgumentError
        raise Invalid, "capacity_unknown"
      end
    end
  end
end
