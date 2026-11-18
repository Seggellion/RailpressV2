require "test_helper"
require "timeout"
require_relative "../support/native_queue_observation"
class QualificationWorkerTest < ActiveSupport::TestCase
  include IdentityTestSupport
  setup { install_site! }
  test "worker observation sees external completion even with a primed queue query cache" do
    pid = nil; fresh = nil
    state = PlatformState.create!(scope_name: "qualification", key_name: "worker", payload: { "count" => 0 })
    original = StateIncrementJob.queue_adapter
    StateIncrementJob.queue_adapter = :solid_queue
    job = StateIncrementJob.perform_later(state.id)
    ids = [ job.provider_job_id ]
    SolidQueue::Job.cache do
      assert_nil SolidQueue::Job.where(id: ids).first.finished_at
      # Prime the exact relation used by the old worker polls.
      SolidQueue::Job.where(id: ids).to_a
      log = Rails.root.join("docs/evidence", ENV.fetch("RAILPRESS_EVIDENCE_MILESTONE"), "#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-qualified-worker.log")
      pid = Process.spawn(RbConfig.ruby, Rails.root.join("bin/jobs").to_s, "--mode", "async", "--skip-recurring", out: log.to_s, err: [ :child, :out ], pgroup: true)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
      loop do
        fresh = SolidQueue::Job.uncached { SolidQueue::Job.where(id: ids).to_a }
        break if fresh.length == 1 && fresh.first.finished_at
        flunk "Native worker did not complete under original20s bound" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.1
      end
      legacy = SolidQueue::Job.where(id: ids).to_a
      observed = NativeQueueObservation.jobs(ids)
      effect = PlatformState.uncached { state.reload.payload["count"] }
      result = { engine: ENV.fetch("RAILPRESS_TEST_ENGINE"), primary_pool: ActiveRecord::Base.connection_pool.object_id, queue_pool: SolidQueue::Job.connection_pool.object_id,
        queue_cache_enabled: SolidQueue::Job.connection_pool.query_cache_enabled, legacy_finished: legacy.map { |row| row.finished_at.present? }, observed_finished: observed.map { |row| row.finished_at.present? },
        uncached_finished: fresh.map { |row| row.finished_at.present? }, committed_effect: effect, scope: "actual native worker;parent SQL cache primed;no host clock change" }
      File.write(Rails.root.join("docs/evidence", ENV.fetch("RAILPRESS_EVIDENCE_MILESTONE"), "#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-worker-cache-proof.json"), JSON.pretty_generate(result) + "\n")
      assert_equal 1, effect
      assert_equal [ false ], result[:legacy_finished], "Control must reproduce stale SQL-cache observation"
      assert_equal [ true ], result[:uncached_finished]
      assert_equal [ true ], result[:observed_finished], "Worker observation must bypass the queue connection pool cache"
    end
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
    StateIncrementJob.queue_adapter = original if original
    SolidQueue::Job.where(id: ids).each(&:destroy!) if ids
    state&.destroy!
  end
end
