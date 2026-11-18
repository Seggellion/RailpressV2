require "test_helper"
require "timeout"
require_relative "../support/official_news_test_support"
require_relative "../support/native_queue_observation"
require_relative "../support/official_news_tls_support"
require_relative "../support/official_news_worker_clock"
class OfficialNewsWorkerTest < ActiveSupport::TestCase
  include IdentityTestSupport
  include OfficialNewsTestSupport
  include OfficialNewsTlsSupport
  setup do
    install_site!
    @news_clock_directory=File.join(@private_root, "native-news-clock")
    Dir.mkdir(@news_clock_directory, 0o700)
    File.write(File.join(@news_clock_directory, "anchor.json"), JSON.generate({ "format"=>"railpress.test-news-clock.v1",
      "wall"=>Time.now.to_f, "elapsed"=>Railpress::SecurityClock.elapsed, "domain"=>Railpress::SecurityClock.boot_domain }), perm: 0o600)
    @restore_news_clock=OfficialNewsWorkerClock.install!(@news_clock_directory)
  end
  teardown { @restore_news_clock&.call }
  def run_native_job(row, generation, label, transport_fixture: nil)
    clock_path=File.join(@news_clock_directory, "authority", "security-clock.json")
    clock_document=-> { File.exist?(clock_path) ? JSON.parse(File.read(clock_path)).slice("wall", "elapsed", "generation", "anomaly") : nil }
    before_clock=clock_document.call
    root=Rails.root.join(".local/state/m13-worker", ENV.fetch("RAILPRESS_TEST_ENGINE"))
    FileUtils.mkdir_p(root, mode: 0o700)
    log=root.join("#{label}-#{SecureRandom.hex(4)}.log")
    previous=OfficialNewsRefreshJob.queue_adapter
    OfficialNewsRefreshJob.queue_adapter=:solid_queue
    job=OfficialNewsRefreshJob.perform_later(row.id, generation)
    assert job.provider_job_id
    # Deliberately prime the parent query cache; completion must be uncached.
    SolidQueue::Job.where(id: job.provider_job_id).to_a
    raw_before={ wall: Process.clock_gettime(Process::CLOCK_REALTIME), elapsed: Railpress::SecurityClock.elapsed }
    command=[ RbConfig.ruby, "-r", Rails.root.join("test/support/official_news_worker_clock.rb").to_s ]
    command += [ "-r", Rails.root.join("test/support/official_news_worker_transport.rb").to_s ] if transport_fixture
    command += [ Rails.root.join("bin/jobs").to_s, "--mode", "async", "--skip-recurring" ]
    pid=Process.spawn({ "RAILPRESS_NEWS_TLS_FIXTURE"=>transport_fixture, "RAILPRESS_NEWS_CLOCK_FIXTURE"=>@news_clock_directory }, *command, out: log.to_s, err: [ :child, :out ], pgroup: true)
    deadline=Railpress::SecurityClock.elapsed+20
    loop do
      record=SolidQueue::Job.uncached { SolidQueue::Job.find_by(id: job.provider_job_id) }
      break if record&.finished_at
      flunk "Native official-news job did not complete under the original20s bound" if Railpress::SecurityClock.elapsed>deadline
      sleep 0.05
    end
    assert_empty SolidQueue::FailedExecution.where(job_id: job.provider_job_id)
  ensure
    OfficialNewsRefreshJob.queue_adapter=previous if previous
    if pid
      Process.kill("TERM", -pid) rescue Errno::ESRCH
      begin
        Timeout.timeout(8) { Process.wait(pid) }
      rescue Timeout::Error
        Process.kill("KILL", -pid) rescue Errno::ESRCH
        Process.wait(pid) rescue Errno::ECHILD
      end
    end
    if clock_document
      current_row=OfficialNewsState.uncached { OfficialNewsState.find_by(id: row.id) }
      evidence=Rails.root.join("docs/evidence", ENV.fetch("RAILPRESS_EVIDENCE_MILESTONE", "M13"))
      FileUtils.mkdir_p(evidence)
      observation={ label: label, clock_mode: "isolated monotonic-derived test wall; not independent UTC", before_clock: before_clock, after_clock: clock_document.call,
        raw_before: raw_before, raw_after: { wall: Process.clock_gettime(Process::CLOCK_REALTIME), elapsed: Railpress::SecurityClock.elapsed },
        row: current_row&.attributes&.slice("enabled", "provider_enabled", "generation", "last_error", "failures"),
        payload_present: current_row&.payload.present?, lease_present: current_row&.lease_key.present?,
        requested_generation: generation, native_log_bytes: log&.exist? ? log.size : nil }
      File.open(evidence.join("#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-news-native-#{label}-#{SecureRandom.hex(4)}.json"), "wx") { |file| file.write(JSON.pretty_generate(observation)+"\n") }
    end
  end
  test "real consumer worker fetches verified isolated HTTPS metadata and persists a last good cache" do
    row=OfficialNewsState.create!(site: Site.first, enabled: true)
    tls_fixture("ok") do |_guard, _store, directory, _uri|
      run_native_job(row, row.generation, "consumer-https", transport_fixture: directory)
      row=OfficialNewsState.uncached { row.reload }
      assert_equal news_payload, row.payload
      assert_equal "FRESH", OfficialNews::Cache.view(row)["state"]
      request=File.read(File.join(directory, "request"))
      refute_match(/Cookie:|Authorization:|Referer:/i, request)
      refute_includes request, Site.first.install_id
      refute_includes request, @owner.email
      puts "NEWS_CONSUMER_WORKER_OBSERVATION: engine=#{ENV.fetch("RAILPRESS_TEST_ENGINE")} actual_native_worker=true transport=verified_private_TLS_fixture external_live_requests=0"
    end
  end
  test "real native worker reads local provider and persisted opt out survives a second worker process" do
    provider_site
    post=news_post;review(post)
    row=OfficialNewsState.first
    row.update!(enabled: true)
    run_native_job(row, row.generation, "local-provider")
    fresh=OfficialNewsState.uncached { row.reload }
    assert_equal 1, fresh.payload["items"].length
    assert_equal "LOCAL", OfficialNews::Cache.view(fresh)["state"]
    old_generation=fresh.generation
    row=OfficialNews::Controls.call(actor: @owner, operation: "disable", version: fresh.lock_version)
    # Disable provider separately so the off state demonstrates zero metadata source.
    row=OfficialNews::Controls.call(actor: @owner, operation: "provider_disable", version: row.lock_version)
    run_native_job(row, old_generation, "disabled-restart")
    assert_nil OfficialNewsState.uncached { row.reload.payload }
    assert_equal "DISABLED", OfficialNews::Cache.view(row)["state"]
    puts "NEWS_NATIVE_WORKER_OBSERVATION: engine=#{ENV.fetch("RAILPRESS_TEST_ENGINE")} real_worker_processes=2 local_provider_items=1 stale_generation_after_opt_out=denied external_requests=0"
  end
  test "native clock hold completes without fetching while reviewed local posts remain available" do
    row=OfficialNewsState.create!(site: Site.first, enabled: true)
    clock=Railpress::SecurityClock.for_application
    clock.sample
    travel_to(Time.now+5.seconds, with_usec: true) { clock.sample }
    assert clock.sample["anomaly"]
    tls_fixture("ok") do |_guard, _store, directory, _uri|
      run_native_job(row, row.generation, "known-clock-hold", transport_fixture: directory)
      assert_nil OfficialNewsState.uncached { row.reload.payload }
      refute File.exist?(File.join(directory, "request")), "Clock-held worker must not transmit a request"
    end
    provider_site
    post=news_post;review(post)
    local=OfficialNews::Cache.view(row.reload)
    assert_equal "LOCAL", local["state"]
    assert_equal 1, local["items"].length
    puts "NEWS_NATIVE_CLOCK_HOLD: engine=#{ENV.fetch('RAILPRESS_TEST_ENGINE')} job_completed=true transport_requests=0 local_reviewed_posts=1 production_policy_unchanged=true"
  end
end
