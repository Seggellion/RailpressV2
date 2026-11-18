require "test_helper"
require "railpress/harness"
require "tmpdir"
require "stringio"

class RailpressHarnessTest < ActiveSupport::TestCase
  setup do
    parent = Rails.root.join(".local/state/harness-tests")
    FileUtils.mkdir_p(parent)
    @directory = Pathname(Dir.mktmpdir("developer-", parent))
    @directory.join("lib/railpress").mkpath
    @directory.join("lib/railpress/product.rb").write("# synthetic developer marker\n")
    @directory.join("Gemfile.lock").write("# synthetic lock marker\n")
    @directory.join("AGENTS.md").write("Canonical synthetic policy: no production, credentials, network or publication.\n")
    @directory.join(".gitignore").write("/.local/\n/docs/evidence/\n")
    assert system({ "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => "/dev/null" }, "git", "init", "--quiet", @directory.to_s)
    @out = StringIO.new
    @err = StringIO.new
    @cli = Railpress::Harness::CLI.new(@directory, out: @out, err: @err)
  end
  teardown do
    raise "unsafe harness fixture cleanup" unless @directory.realpath.to_s.start_with?(Rails.root.join(".local/state/harness-tests").realpath.to_s + "/")
    FileUtils.remove_entry_secure(@directory)
  end

  def call(*args)
    @out.truncate(0); @out.rewind; @err.truncate(0); @err.rewind
    @cli.run(args)
  end

  def plan
    assert_equal 0, call("plan", "reading_time")
    JSON.parse(@out.string)
  end

  def scaffold(document = plan, *extra)
    call("scaffold", "reading_time", "--review", document["review_sha256"], "--confirm-development", *extra)
  end

  def files
    @directory.glob("**/*", File::FNM_DOTMATCH).select(&:file?).to_h { |p| [ p.relative_path_from(@directory).to_s, Digest::SHA256.file(p).hexdigest ] }
  end

  test "doctor plan and report do not write source Git or private state" do
    before = files
    %w[doctor report].each { |verb| assert_equal 0, call(verb) }
    document = plan
    assert_empty document["mounted_routes"]
    assert_empty document["migrations"]
    assert_empty document["permission_grants"]
    assert_equal Digest::SHA256.file(@directory.join("AGENTS.md")).hexdigest, document["policy_sha256"]
    assert_equal before, files
    refute @directory.join(".local").exist?
  end

  test "hostile names and shell path payloads cannot create files or execute commands" do
    before = files
    [ "../escape", "/tmp/escape", "a/b", "a\\b", "a;touch pwned", "$(touch pwned)", "a\nb", "x" * 41, "café", "--push", "admin", "security_clock", "ReadingTime", "a__b", "feature_1", "" ].each do |name|
      assert_equal 1, call("plan", name)
    end
    assert_equal before, files
    refute @directory.join("pwned").exist?
  end

  test "unknown dangerous verbs duplicate options and auto push are refused" do
    %w[push commit deploy reset clean install].each { |verb| assert_equal 1, call(verb) }
    [ [ "--force" ], [ "--push" ], [ "--review", "a" * 64, "--review", "b" * 64 ], [ "--review" ] ].each { |options| assert_equal 1, call("scaffold", "reading_time", *options) }
    refute @directory.join(".local").exist?
  end

  test "scaffold requires development confirmation and an exact current review" do
    document = plan
    assert_equal 1, call("scaffold", "reading_time", "--review", document["review_sha256"])
    assert_equal 1, call("scaffold", "reading_time", "--confirm-development", "--review", "a" * 64)
    document["files"].each_key { |name| refute @directory.join(name).exist? }
  end

  test "review becomes stale after source or canonical policy changes" do
    document = plan
    @directory.join("AGENTS.md").write("Changed review boundary.\n")
    assert_equal 1, scaffold(document)
    refute @directory.join(".local").exist?
  end

  test "reviewed scaffold creates only five unmounted development files and repeats idempotently" do
    document = plan
    assert_equal 0, scaffold(document), @err.string
    before = document["files"].to_h { |name, text| [ name, Digest::SHA256.hexdigest(text) ] }
    before.each { |name, digest| assert_equal digest, Digest::SHA256.file(@directory.join(name)).hexdigest }
    refute @directory.join("config/routes.rb").exist?
    refute @directory.join("db").exist?
    assert_includes @directory.join("app/controllers/harness_extensions/reading_time_controller.rb").read, "head :not_found"
    assert_equal 0, scaffold(document), @err.string
    assert JSON.parse(@out.string)["resume_or_repeat"]
    assert_equal 0, call("report")
    assert JSON.parse(@out.string)["receipts"].all? { |row| row["source_current"] }
  end

  test "unowned collisions never overwrite user files" do
    document = plan
    name = document["files"].keys.first
    @directory.join(name).dirname.mkpath
    @directory.join(name).write("Unrelated user work.\n")
    assert_equal 1, scaffold(document)
    assert_equal "Unrelated user work.\n", @directory.join(name).read
    refute @directory.join(".local/harness/reading_time.json").exist?
  end

  test "symlink parents cannot escape the developer root" do
    document = plan
    @directory.join("app").mkpath
    outside = @directory.join(".local/outside"); outside.mkpath
    File.symlink(outside, @directory.join("app/controllers"))
    assert_equal 1, scaffold(document)
    assert_empty outside.children
  end

  test "held mutation lock refuses concurrent writer without partial files" do
    document = plan
    parent = @cli.private_directory(".local/harness")
    File.open(parent.join("lock"), "w", 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      assert_equal 1, scaffold(document)
      document["files"].each_key { |name| refute @directory.join(name).exist? }
    end
  end

  test "partial owned scaffold needs explicit resume and conserves earlier bytes" do
    document = plan
    parent = @cli.private_directory(".local/harness")
    hashes = document["files"].transform_values { |text| Digest::SHA256.hexdigest(text) }
    @cli.write_state(parent.join("reading_time.json"), { "format" => "railpress.harness.scaffold.v1", "feature" => "reading_time", "review_sha256" => document["review_sha256"], "files" => hashes, "phase" => "WRITING" })
    first = document["files"].first
    @directory.join(first[0]).dirname.mkpath; @directory.join(first[0]).write(first[1])
    File.utime(Time.at(10), Time.at(10), @directory.join(first[0]))
    assert_equal 1, scaffold(document)
    assert_equal 0, scaffold(document, "--resume"), @err.string
    assert_equal Time.at(10), @directory.join(first[0]).mtime
    assert_equal "COMPLETE", JSON.parse(parent.join("reading_time.json").read)["phase"]
  end

  test "edited generated files are preserved and report becomes stale" do
    document = plan
    assert_equal 0, scaffold(document)
    first = @directory.join(document["files"].keys.first); first.write("Changed by developer.\n")
    assert_equal 1, scaffold(document, "--resume")
    assert_equal "Changed by developer.\n", first.read
    assert_equal 0, call("report")
    assert_equal "STALE_OR_CONFLICT", JSON.parse(@out.string)["receipts"].first["phase"]
  end

  test "private state symlinks and insecure modes are refused" do
    document = plan
    parent = @cli.private_directory(".local/harness")
    outside = @directory.join("outside.json"); outside.write("{}")
    File.symlink(outside, parent.join("reading_time.json"))
    assert_equal 1, scaffold(document)
    assert_equal "{}", outside.read
    parent.join("reading_time.json").unlink
    parent.chmod(0o777)
    assert_equal 1, scaffold(document)
  end

  test "accidental source secrets are refused without disclosure" do
    secret = "sk-" + "x" * 48
    @directory.join("accidental_config.rb").write(secret)
    assert_equal 1, call("doctor")
    refute_includes @out.string + @err.string, secret
  end

  test "connection overrides are refused before any database or source operation" do
    prior = ENV["DATABASE_URL"]
    secret = "synthetic-private-value"
    ENV["DATABASE_URL"] = "postgresql://owner:#{secret}@production.invalid/site"
    %w[doctor report].each { |verb| assert_equal 1, call(verb) }
    assert_equal 1, call("verify", "--engine", "postgresql", "--confirm-synthetic")
    refute_includes @out.string + @err.string, secret
    refute @directory.join(".local").exist?
  ensure
    ENV["DATABASE_URL"] = prior
  end

  test "production environment and inherited Git override are refused" do
    prior = ENV["RAILS_ENV"]; ENV["RAILS_ENV"] = "production"
    assert_equal 1, call("plan", "reading_time")
    ENV["RAILS_ENV"] = prior
    prior_git = ENV["GIT_INDEX_FILE"]; ENV["GIT_INDEX_FILE"] = "/not/an/authorized/index"
    assert_equal 1, call("doctor")
  ensure
    ENV["RAILS_ENV"] = prior
    ENV["GIT_INDEX_FILE"] = prior_git
  end

  test "verification refuses absent confirmation unknown suite and unidentified database" do
    assert_equal 1, call("verify")
    assert_equal 1, call("verify", "--engine", "postgresql", "--suite", "publish", "--confirm-synthetic")
    assert_equal 1, call("verify", "--engine", "postgresql", "--confirm-synthetic")
    assert_includes @err.string, "synthetic database admission refused"
    refute @directory.join(".local/harness/verifications").exist?
  end

  test "tampered report fields are rejected rather than echoed" do
    parent = @cli.private_directory(".local/harness")
    @cli.write_state(parent.join("bad.json"), { "format" => "railpress.harness.scaffold.v1", "phase" => "COMPLETE", "feature" => "../private-secret" })
    assert_equal 1, call("report")
    refute_includes @out.string + @err.string, "private-secret"
  end

  test "generic extension acceptance remains an honest failing skeleton" do
    assert_equal 0, call("plan", "feature_note")
    data = JSON.parse(@out.string)
    assert_includes data["files"]["test/harness_extensions/feature_note_test.rb"], "flunk"
    assert_empty data["mounted_routes"]
  end

  test "real child failure keeps bounded private output and reports its exit" do
    log = @directory.join("command.log")
    result = @cli.command([ RbConfig.ruby, "-e", "puts 'synthetic child failure'; exit 3" ], log)
    assert_equal 3, result
    assert_equal "synthetic child failure\n", log.read
    assert_equal 0, log.stat.mode & 0o077
  end

  test "interruption terminates and reaps only the owned command group" do
    require "timeout"
    log = @directory.join("cancel.log")
    thread = Thread.new do
      @cli.command([ RbConfig.ruby, "-e", "STDOUT.sync=true; puts Process.pid; sleep 30" ], log)
    rescue Railpress::Harness::Refused
      :controlled_cancellation
    end
    Timeout.timeout(3) { sleep 0.02 until log.file? && log.size.positive? }
    pid = Integer(log.read.strip)
    thread.raise(Railpress::Harness::Refused, "controlled cancellation")
    assert thread.join(5), "owned command cleanup must complete"
    assert_equal :controlled_cancellation, thread.value
    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
  ensure
    thread&.kill if thread&.alive?
    thread&.join
  end

  test "output bound does not impose a size limit on unrelated application files" do
    log = @directory.join("output.log")
    result = @cli.command([ RbConfig.ruby, "-e", "File.write('application.log', 'x' * (3 * 1024 * 1024)); puts 'complete'" ], log)
    assert_equal 0, result
    assert_equal 3 * 1024 * 1024, @directory.join("application.log").size
    assert_equal "complete\n", log.read
  end

  test "actual oversized command output is capped and refused" do
    log = @directory.join("bounded.log")
    error = assert_raises(Railpress::Harness::Refused) { @cli.command([ RbConfig.ruby, "-e", "STDOUT.write('x' * (3 * 1024 * 1024))" ], log) }
    assert_includes error.message, "2MiB"
    assert_equal 2 * 1024 * 1024, log.size
  end

  test "verification and scaffolding share one nonblocking mutation lock" do
    acquired = false
    @cli.with_mutation_lock do
      acquired = true
      assert_raises(Railpress::Harness::Refused) { @cli.with_mutation_lock { flunk "second writer must not run" } }
      assert_equal 1, call("verify", "--engine", "postgresql", "--confirm-synthetic")
      assert_includes @err.string, "active"
    end
    assert acquired
    @cli.with_mutation_lock { assert true }
  end
end
