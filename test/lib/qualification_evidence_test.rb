require "test_helper"
require_relative "../support/qualification_evidence"
require_relative "../support/news_trace"

class QualificationEvidenceTest < ActiveSupport::TestCase
  setup do
    base=Rails.root.join(".local/state/m02-tests", ENV.fetch("RAILPRESS_TEST_ENGINE"))
    FileUtils.mkdir_p(base)
    @roots=[ Dir.mktmpdir("identity-evidence-", base) ]
    @root=@roots.first
  end
  teardown do
    # These are owned intentional unit-control markers, never failed-run roots.
    @roots.each { |path| FileUtils.remove_entry_secure(path) if passed? && File.directory?(path) && !File.symlink?(path) }
  end
  test "failure marker retains owned bytes with private mode and refuses ordinary cleanup" do
    bytes="synthetic private clock bytes"
    File.write(File.join(@root, "clock.json"), bytes, perm: 0o600)
    marker=QualificationEvidence.retain!(@root, test: "synthetic failure", classes: [ "Minitest::Assertion" ])
    assert_equal bytes, File.binread(File.join(@root, "clock.json"))
    assert_equal 0o600, File.stat(marker).mode & 0o777
    assert_equal [ "Minitest::Assertion" ], JSON.parse(File.read(marker))["error_classes"]
    assert_raises(RuntimeError) { QualificationEvidence.remove!(@root) }
    assert File.directory?(@root)
  end
  test "retention is idempotent without overwriting the original evidence" do
    marker=QualificationEvidence.retain!(@root, test: "same case", classes: [ "Minitest::Assertion" ])
    before=File.binread(marker)
    assert_equal marker, QualificationEvidence.retain!(@root, test: "same case", classes: [ "RuntimeError" ])
    assert_equal before, File.binread(marker)
    assert_raises(RuntimeError) { QualificationEvidence.retain!(@root, test: "other case", classes: []) }
    assert_equal before, File.binread(marker)
  end
  test "unsafe roots and marker links refuse without touching their target" do
    other=Dir.mktmpdir("identity-evidence-target-", File.dirname(@root));@roots<<other
    file=File.join(other, "original")
    File.write(file, "untouched", perm: 0o600)
    File.symlink(file, File.join(@root, "qualification-failure.json"))
    assert_raises(RuntimeError) { QualificationEvidence.retain!(@root, test: "case", classes: []) }
    assert_equal "untouched", File.read(file)
    assert_raises(RuntimeError) { QualificationEvidence.root!(File.dirname(@root)) }
  end
  test "successful unmarked fixture cleanup remains scoped" do
    QualificationEvidence.remove!(@root)
    refute File.exist?(@root)
    assert File.directory?(File.dirname(@root))
  end
  test "news trace keeps observation counts and exports no raw bindings or validators" do
    clock_root=File.join(@root, "clock");Dir.mkdir(clock_root, 0o700)
    clock=Class.new do
      attr_reader :calls
      define_method(:initialize) { |root| @root=root;@calls=0 }
      define_method(:sample) do
        @calls+=1
        { "wall" => 100.0, "elapsed" => 10.0, "generation" => 0, "segments" => [ { "generation" => 0, "maximum" => 100.0 } ],
          "domain" => "private-test-domain", "epoch" => "private-test-epoch", "anomaly" => nil }
      end
      define_method(:valid?) { |*_, **_| true }
    end.new(clock_root)
    File.write(File.join(clock_root, "security-clock.json"), JSON.generate(clock.sample), perm: 0o600)
    baseline=clock.calls
    client=Class.new do
      attr_reader :calls, :headers
      def initialize;@calls=0;@headers=[];end
      def get(**options);@calls+=1;@headers<<options;Struct.new(:status).new(200);end
    end.new
    refresh=Class.new do
      define_method(:initialize) { |time, transport| @clock=time;@client=transport }
      def call(*)
        @client.get(etag: "private-test-validator", last_modified: "private-test-modified") if eligible?(nil, 1)
      end
      private
      def eligible?(*) = !@clock.sample["anomaly"]
    end.new(clock, client)
    trace=NewsTrace.new(self, clock, client, refresh)
    refresh.call(1, 1)
    assert trace.dispatches_authorized?
    binding={ "version" => 2, "domain" => "private-test-domain", "epoch" => "private-test-epoch", "wall_deadline" => 200.0 }
    assert OfficialNews::Cache.valid?(clock, binding, 30)
    value=trace.finish!(@root, nil)
    assert_equal baseline+1, clock.calls
    assert_equal 1, client.calls
    encoded=JSON.generate(value)
    %w[private-test-domain private-test-epoch private-test-validator private-test-modified].each do |secret|
      refute encoded.include?(secret), "public trace contains a raw private binding/validator"
    end
    private_file=File.join(value["private_directory"], "clock-0.private.json")
    assert_equal 0o600, File.stat(private_file).mode & 0o777
    assert File.read(private_file).include?("private-test-epoch")
  end
end
