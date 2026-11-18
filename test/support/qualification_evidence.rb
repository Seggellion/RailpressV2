require "json"
require "fileutils"

# Private test evidence only. Never a production recovery/export authority.
module QualificationEvidence
  module_function
  def root!(path)
    root = File.expand_path(path.to_s)
    base = Rails.root.join(".local/state/m02-tests").realpath.to_s
    stat = File.lstat(root)
    raise "Unsafe qualification evidence root" unless !stat.symlink? && stat.directory? && stat.uid == Process.uid &&
      (stat.mode & 0o077).zero? && File.realpath(root).start_with?(base + "/") && File.basename(root).start_with?("identity-")
    root
  end
  def retain!(path, test:, classes:)
    root = root!(path)
    marker = File.join(root, "qualification-failure.json")
    if File.exist?(marker) || File.symlink?(marker)
      stat = File.lstat(marker)
      raise "Unsafe qualification evidence marker" unless stat.file? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o077).zero? && stat.size <= 8192
      previous = JSON.parse(File.read(marker))
      raise "Conflicting qualification evidence" unless previous["test"] == test.to_s.scrub[0, 512]
      return marker
    end
    names = Array(classes).first(16).map { |name| name.to_s.match?(/\A[A-Za-z_]\w*(?:::[A-Za-z_]\w*)*\z/) ? name.to_s : "UnknownException" }
    value = { "format" => "railpress.test-failure.v1", "test" => test.to_s.scrub[0, 512], "error_classes" => names,
      "scope" => "private fixture retained before SQL/reset cleanup; not a database snapshot" }
    File.open(marker, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
      file.write(JSON.generate(value));file.flush;file.fsync
    end
    marker
  end
  def remove!(path)
    root = root!(path)
    raise "Refuse retained failed fixture cleanup" if File.exist?(File.join(root, "qualification-failure.json")) || File.symlink?(File.join(root, "qualification-failure.json"))
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).each { |entry| File.chmod(0o700, entry) if File.directory?(entry) && !File.symlink?(entry) }
    FileUtils.remove_entry_secure(root)
  end
end
