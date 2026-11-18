require "test_helper"
require "timeout"
require_relative "../support/portability_test_support"
require_relative "../support/native_queue_observation"
class PortabilityNativeWorkerTest < ActiveSupport::TestCase
  include IdentityTestSupport
  include PortabilityTestSupport
  def dispatch_phase(batch, expected_state)
    jobs = 2.times.map { PortabilityImportJob.perform_later(batch.id) }
    ids = jobs.map(&:provider_job_id)
    assert ids.all?
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 25
    loop do
      rows = NativeQueueObservation.jobs(ids)
      break if batch.reload.state == expected_state && rows.length == 2 && rows.all? { |row| row.finished_at.present? }
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        flunk "Native portability phase did not finish: expected=#{expected_state} actual=#{batch.state} failure=#{batch.failure}"
      end
      sleep 0.1
    end
    assert_equal 0, SolidQueue::FailedExecution.where(job_id: ids).count
  end
  test "real native worker inspects stages activates and reverses once under duplicate delivery" do
    install_site!
    session_id = portability_session
    manifest = portable_manifest
    batch = submit_portable(manifest, session_id: session_id)
    previous = PortabilityImportJob.queue_adapter
    PortabilityImportJob.queue_adapter = :solid_queue
    directory = Rails.root.join("docs/evidence", ENV.fetch("RAILPRESS_EVIDENCE_MILESTONE", "M15/native-worker"))
    FileUtils.mkdir_p(directory)
    log = directory.join("#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-portability-worker.log")
    pid = Process.spawn(RbConfig.ruby, Rails.root.join("bin/jobs").to_s, "--mode", "async", "--skip-recurring", out: log.to_s, err: [ :child, :out ], pgroup: true)
    dispatch_phase(batch, "review")
    assert_empty Content.all
    Portability::Imports.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.lock_version, decisions: portable_decisions(manifest))
    dispatch_phase(batch, "staged")
    assert_equal 1, Content.count
    assert_empty Content.publicly_visible
    Portability::Activation.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.lock_version, content_refs: [ manifest["content"][0]["ref"] ], menus: false, settings: false, appearance: false)
    dispatch_phase(batch, "complete")
    assert_equal 1, Content.publicly_visible.count
    Portability::Reversal.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.lock_version)
    dispatch_phase(batch, "reversed")
    assert_empty Content.all
    assert_equal 1, batch.import_events.where(event: "records_reversed").count
    puts "PORTABILITY_NATIVE_WORKER: engine=#{ENV.fetch('RAILPRESS_TEST_ENGINE')} real_process=true phases=4 duplicate_jobs=8 private_staging=true single_activation_and_reversal=true"
  ensure
    if pid
      Process.kill("TERM", -pid) rescue Errno::ESRCH
      begin
        Timeout.timeout(8) { Process.wait(pid) }
      rescue Timeout::Error
        Process.kill("KILL", -pid) rescue Errno::ESRCH
        Process.wait(pid) rescue Errno::ECHILD
      end
    end
    PortabilityImportJob.queue_adapter = previous if previous
  end
end
