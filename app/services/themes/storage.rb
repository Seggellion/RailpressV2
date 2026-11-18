require "fileutils"
require "tmpdir"
module Themes
  module Storage
    module_function
    def root
      candidate = ENV.fetch("RAILPRESS_THEME_ROOT") { Rails.root.join(".local/state/themes", Rails.env, ENV.fetch("RAILPRESS_TEST_ENGINE", "local")).to_s }
      raise Railpress::ThemePackage::Invalid, "persistent_theme_root_required" if Rails.env.production? && (!ENV["RAILPRESS_THEME_ROOT"] || !File.directory?(candidate))
      raise Railpress::ThemePackage::Invalid, "absolute_theme_root_required" unless candidate.start_with?("/") && File.expand_path(candidate) == candidate && !File.symlink?(candidate)
      if Rails.env.production?
        actual = File.realpath(candidate)
        release = Rails.root.realpath.to_s
        raise Railpress::ThemePackage::Invalid, "theme_root_inside_release" if actual == release || actual.start_with?(release + "/")
      end
      FileUtils.mkdir_p(candidate, mode: 0o700)
      stat = File.stat(candidate)
      raise Railpress::ThemePackage::Invalid, "private_theme_root_required" unless stat.uid == Process.uid && (stat.mode & 0o077).zero?
      raise Railpress::ThemePackage::Invalid, "symlink_parent" unless File.realpath(candidate) == candidate
      candidate
    end
    def trusted_keys
      path = File.join(root, "trusted-keys.json")
      raise Railpress::ThemePackage::Invalid, "operator_trust_store_required" unless File.file?(path) && !File.symlink?(path)
      stat = File.stat(path)
      raise Railpress::ThemePackage::Invalid, "unsafe_trust_store" unless stat.uid == Process.uid && (stat.mode & 0o022).zero? && stat.size <= 65_536
      keys = Railpress::ThemePackage.parse(File.binread(path))
      raise Railpress::ThemePackage::Invalid, "invalid_trust_store" unless keys.is_a?(Hash) && keys.length.between?(1, 8)
      keys
    end
    def path(id, version, digest)
      Railpress::ThemePackage.identity!(id, version, digest)
      target = File.join(root, "packages", id, version, digest)
      parent = File.dirname(target)
      while parent.start_with?(root + "/")
        raise Railpress::ThemePackage::Invalid, "symlink_parent" if File.symlink?(parent)
        parent = File.dirname(parent)
      end
      target
    end
    def load(installation, allow_removed: false)
      raise Railpress::ThemePackage::Invalid, "package_removed" unless installation.status == "validated" || (allow_removed && installation.ever_active_at)
      bundle = Railpress::ThemePackage.load(path(installation.theme_key, installation.version, installation.digest), trusted_keys: trusted_keys)
      raise Railpress::ThemePackage::Invalid, "catalog_digest" unless bundle.digest == installation.digest && bundle.manifest["id"] == installation.theme_key && bundle.manifest["version"] == installation.version
      bundle
    end
    def install(bundle)
      File.open(File.join(root, "install.lock"), File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        install_locked(bundle)
      end
    end
    def install_locked(bundle)
      destination = path(bundle.manifest["id"], bundle.manifest["version"], bundle.digest)
      return destination if File.directory?(destination) && Railpress::ThemePackage.load(destination, trusted_keys: trusted_keys).digest == bundle.digest
      FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
      temporary = Dir.mktmpdir("stage-", File.dirname(destination))
      begin
        bundle.files.each do |name, bytes|
          target = File.join(temporary, name)
          FileUtils.mkdir_p(File.dirname(target), mode: 0o700)
          File.open(target, File::WRONLY | File::CREAT | File::EXCL, 0o400) { |file| file.binmode; file.write(bytes); file.flush; file.fsync }
        end
        Dir.glob(File.join(temporary, "**", "*")).select { |entry| File.directory?(entry) }.each { |entry| File.chmod(0o500, entry) }
        File.chmod(0o500, temporary)
        File.rename(temporary, destination)
      ensure
        if File.directory?(temporary)
          Dir.glob(File.join(temporary, "**", "*")).select { |entry| File.directory?(entry) }.each { |entry| File.chmod(0o700, entry) }
          File.chmod(0o700, temporary)
          FileUtils.remove_entry_secure(temporary)
        end
      end
      destination
    end
  end
end
