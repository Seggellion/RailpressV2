require "test_helper"
require "timeout"
require_relative "../support/installation_test_support"

class StorageConfigurationWorkerTest < ActiveSupport::TestCase
  include InstallationTestSupport
  test "actual worker reports matching boot bounded configuration and drift fails closed" do
    prepare_install_schema
    claim = @state.claim!(@state.issue!)
    wizard = Installation::Wizard.new(@state)
    wizard.start!(claim)
    Installation::Progress::STEPS[0...-1].each { |step| wizard.advance!(claim: claim, revision: wizard.progress.read["revision"], step: step, fields: install_fields(step)) }
    Installation::Finish.call(state: @state, claim: claim, revision: wizard.progress.read["revision"])
    assert_equal "NOT TESTED", MediaLibrary::Configuration.agreement["state"]
    refute MediaLibrary::Configuration.record_worker!, "web/inline execution is not a worker observation"
    original = StorageConfigurationJob.queue_adapter
    StorageConfigurationJob.queue_adapter = :solid_queue
    job = StorageConfigurationJob.perform_later
    log = Rails.root.join("docs/evidence/#{ENV.fetch('RAILPRESS_EVIDENCE_MILESTONE', 'qualification')}/#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-storage-worker.log")
    FileUtils.mkdir_p(log.dirname)
    pid = Process.spawn(RbConfig.ruby, Rails.root.join("bin/jobs").to_s, "--mode", "async", "--skip-recurring", out: log.to_s, err: [ :child, :out ], pgroup: true)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
    until MediaLibrary::Configuration.agreement["state"] == "CONFIGURED"
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        trace = ActiveRecord::Base.uncached do
          { "parent_fingerprint" => MediaLibrary::Configuration.fingerprint, "parent_runtime" => MediaLibrary::Configuration.runtime,
            "uncached_worker" => PlatformState.find_by(scope_name: "media_configuration", key_name: "worker")&.payload,
            "uncached_agreement" => MediaLibrary::Configuration.agreement, "transaction_open" => ActiveRecord::Base.connection.transaction_open?,
            "workers" => SolidQueue::Process.all.map { |row| row.attributes.slice("id", "kind", "pid", "last_heartbeat_at") },
            "jobs" => SolidQueue::Job.where(id: job.provider_job_id).map { |row| row.attributes.slice("id", "class_name", "finished_at") },
            "failed_classes" => SolidQueue::FailedExecution.where(job_id: job.provider_job_id).map(&:exception_class) }
        end
        File.write(log.to_s + ".deadline.json", JSON.pretty_generate(trace))
        flunk "Actual storage worker deadline; retained log #{log.basename}"
      end
      sleep 0.1
    end
    assert_equal "CONFIGURED", MediaLibrary::Configuration.agreement["state"]
    row = PlatformState.find_by!(scope_name: "media_configuration", key_name: "worker")
    ready_fingerprint = Readiness::Assessment.fingerprint(Site.first)
    report_id, report = row.payload.fetch("reports").first
    assert report["binding"]["deadline"] > report["binding"]["issued_elapsed"]
    # A second live registration cannot be hidden by the first worker's report.
    extra = SolidQueue::Process.create!(kind: "Worker", pid: Process.pid, hostname: Socket.gethostname, name: SecureRandom.hex(12), last_heartbeat_at: Time.now)
    assert_equal "NOT TESTED", MediaLibrary::Configuration.agreement["state"]
    refute_equal ready_fingerprint["storage_worker"], Readiness::Assessment.fingerprint(Site.first)["storage_worker"]
    extra.destroy!
    before = ENV["RAILPRESS_STORAGE_CONFIG_EPOCH"]
    ENV["RAILPRESS_STORAGE_CONFIG_EPOCH"] = "changed-after-restart"
    assert_equal "ACTION REQUIRED", MediaLibrary::Configuration.agreement["state"]
    expired = report.merge("binding" => report["binding"].merge("deadline" => 0))
    row.update!(payload: row.payload.merge("reports" => row.payload["reports"].merge(report_id => expired)))
    assert_equal "NOT TESTED", MediaLibrary::Configuration.agreement["state"]
    refute_equal ready_fingerprint["storage_worker"], Readiness::Assessment.fingerprint(Site.first)["storage_worker"]
    puts "STORAGE_CONFIG_WORKER: engine=#{ENV.fetch('RAILPRESS_TEST_ENGINE')} actual_worker=true mismatch=denied stale=denied provider_calls=0"
    completed = true
  ensure
    ENV["RAILPRESS_STORAGE_CONFIG_EPOCH"] = before if defined?(before)
    extra&.destroy! if defined?(extra) && extra&.persisted?
    if pid
      Process.kill("TERM", -pid) rescue Errno::ESRCH
      begin
        Timeout.timeout(8) { Process.wait(pid) }
      rescue Timeout::Error
        Process.kill("KILL", -pid) rescue Errno::ESRCH
        Process.wait(pid) rescue Errno::ECHILD
      end
    end
    StorageConfigurationJob.queue_adapter = original if original
    SolidQueue::Job.find_by(id: job.provider_job_id)&.destroy! if job && completed
  end
end
