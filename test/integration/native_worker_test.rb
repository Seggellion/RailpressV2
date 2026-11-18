require "test_helper"
require "timeout"

class NativeWorkerTest < ActiveSupport::TestCase
  include IdentityTestSupport
  setup { install_site! }
  self.use_transactional_tests = false

  test "actual native worker executes a persisted job" do
    state = PlatformState.create!(scope_name: "worker", key_name: "execution", payload: { "count" => 0 })
    original_adapter = StateIncrementJob.queue_adapter
    StateIncrementJob.queue_adapter = :solid_queue
    job = StateIncrementJob.perform_later(state.id)
    assert job.provider_job_id
    log = Rails.root.join("docs/evidence/#{ENV.fetch('RAILPRESS_EVIDENCE_MILESTONE', 'M06')}/#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-worker.log")
    pid = Process.spawn(RbConfig.ruby, Rails.root.join("bin/jobs").to_s, "--mode", "async", "--skip-recurring", out: log.to_s, err: [ :child, :out ], pgroup: true)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
    until state.reload.payload["count"] == 1
      flunk "native worker failed; inspect #{log.basename}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.1
    end
    assert_equal 1, state.payload["count"]
    assert_nil SolidQueue::FailedExecution.find_by(job_id: job.provider_job_id)
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
    StateIncrementJob.queue_adapter = original_adapter if original_adapter
    SolidQueue::Job.find_by(id: job.provider_job_id)&.destroy! if job
    state&.destroy!
  end
end
