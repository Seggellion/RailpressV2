require "test_helper"
require "timeout"
require_relative "../support/native_queue_observation"
require_relative "../support/seo_test_support"
class SeoNativeWorkerTest < ActiveSupport::TestCase
  include SeoTestSupport
  test "actual native worker executes offline diagnostics once under duplicate delivery" do
    public_content
    original=SeoDiagnosticJob.queue_adapter
    SeoDiagnosticJob.queue_adapter=:solid_queue
    run=Seo::Diagnostics.start!(actor: @owner)
    second=SeoDiagnosticJob.perform_later(run.id)
    job_ids=SolidQueue::Job.where(class_name: "SeoDiagnosticJob").pluck(:id)
    assert_equal 2, job_ids.length
    log=Rails.root.join("docs/evidence/#{ENV.fetch('RAILPRESS_EVIDENCE_MILESTONE', 'M06')}/#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-seo-worker.log")
    pid=Process.spawn(RbConfig.ruby, Rails.root.join("bin/jobs").to_s, "--mode", "async", "--skip-recurring", out: log.to_s, err: [ :child, :out ], pgroup: true)
    deadline=Process.clock_gettime(Process::CLOCK_MONOTONIC)+30
    loop do
      rows=NativeQueueObservation.jobs(job_ids)
      break if run.reload.status=="completed" && rows.length==2 && rows.all? { |row|row.finished_at.present? }
      if Process.clock_gettime(Process::CLOCK_MONOTONIC)>deadline
        state=SolidQueue::Job.uncached do
          ActiveRecord::Base.uncached do
          { engine: ENV.fetch("RAILPRESS_TEST_ENGINE"), run_status: run.reload.status,
            transaction_open: ActiveRecord::Base.connection.transaction_open?,
            jobs: SolidQueue::Job.where(id: job_ids).map { |job|job.attributes.slice("id", "finished_at", "queue_name") },
            failed_classes: SolidQueue::FailedExecution.where(job_id: job_ids).map(&:exception_class),
            ready: SolidQueue::ReadyExecution.where(job_id: job_ids).count,
            claimed: SolidQueue::ClaimedExecution.where(job_id: job_ids).count }
        end
        end
        File.write(Rails.root.join("docs/evidence/#{ENV.fetch('RAILPRESS_EVIDENCE_MILESTONE', 'M06')}/#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-seo-worker-deadline-#{SecureRandom.hex(3)}.json"), JSON.pretty_generate(state)+"\n")
        flunk "Native SEO worker deadline; run=#{run.status}"
      end
      sleep 0.1
    end
    assert_equal 2, run.summary["checked"]
    assert_empty run.summary["codes"]
    assert_nil run.active_key
    assert_equal 0, SolidQueue::FailedExecution.where(job_id: job_ids).count
    puts "SEO_NATIVE_WORKER_OBSERVATION: adapter=#{ENV.fetch('RAILPRESS_TEST_ENGINE')} duplicate_jobs=2 completed_run=1 checked_targets=2"
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
    SeoDiagnosticJob.queue_adapter=original if original
    SolidQueue::Job.where(id: job_ids).each(&:destroy!) if job_ids
  end
end
