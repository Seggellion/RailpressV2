require "test_helper"
require "timeout"
require_relative "../support/native_queue_observation"
require_relative "../support/editorial_test_support"
require_relative "../support/official_news_worker_clock"

class EditorialNativeWorkerTest < ActiveSupport::TestCase
  include EditorialTestSupport
  setup do
    @worker_clock_directory = File.join(@private_root, "native-editorial-clock")
    Dir.mkdir(@worker_clock_directory, 0o700)
    File.write(File.join(@worker_clock_directory, "anchor.json"), JSON.generate({ "format" => "railpress.test-news-clock.v1",
      "wall" => Time.now.to_f, "elapsed" => Railpress::SecurityClock.elapsed, "domain" => Railpress::SecurityClock.boot_domain }), perm: 0o600)
    @restore_worker_clock = OfficialNewsWorkerClock.install!(@worker_clock_directory)
  end
  teardown { @restore_worker_clock&.call }

  def scheduled_item
    item = draft
    local = 2.hours.from_now.in_time_zone(Site.first.timezone).strftime("%Y-%m-%dT%H:%M")
    change(item, "schedule", attributes: { schedule_local: local })
    item.update_columns(scheduled_at: 1.minute.ago)
    item
  end

  def run_duplicate_jobs(item, held: false)
    original = PublishContentJob.queue_adapter
    PublishContentJob.queue_adapter = :solid_queue
    jobs = 2.times.map { PublishContentJob.perform_later(item.id, item.lock_version) }
    assert jobs.all?(&:provider_job_id)
    Railpress::SecurityClock.for_application.sample
    clock_path=File.join(@worker_clock_directory, "authority", "security-clock.json")
    clock_before=JSON.parse(File.read(clock_path)).slice("wall", "elapsed", "generation", "anomaly")
    log = Rails.root.join("docs/evidence/#{ENV.fetch('RAILPRESS_EVIDENCE_MILESTONE', 'M06')}/#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-editorial-worker.log")
    pid = Process.spawn({ "RAILPRESS_NEWS_CLOCK_FIXTURE" => @worker_clock_directory }, RbConfig.ruby,
      "-r", Rails.root.join("test/support/official_news_worker_clock.rb").to_s, Rails.root.join("bin/jobs").to_s, "--mode", "async", "--skip-recurring",
      out: log.to_s, err: [ :child, :out ], pgroup: true)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 25
    loop do
      rows = NativeQueueObservation.jobs(jobs.map(&:provider_job_id))
      break if (held || item.reload.status == "published") && rows.length == jobs.length && rows.all? { |row| row.finished_at.present? }
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        state=SolidQueue::Job.uncached do
          ActiveRecord::Base.uncached do
          { engine: ENV.fetch("RAILPRESS_TEST_ENGINE"), status: item.reload.status, scheduled_at: item.scheduled_at, now: Time.current.iso8601(6),
            expected_version: jobs.first.arguments.last, current_version: item.lock_version,
            scheduled_actor_role: User.find_by(id: item.scheduled_by_id)&.role,
            clock_before: clock_before, clock_after: JSON.parse(File.read(clock_path)).slice("wall", "elapsed", "generation", "anomaly"),
            transaction_open: ActiveRecord::Base.connection.transaction_open?,
            jobs: SolidQueue::Job.where(id: jobs.map(&:provider_job_id)).map { |job|job.attributes.slice("id", "scheduled_at", "finished_at") },
            failed_classes: SolidQueue::FailedExecution.where(job_id: jobs.map(&:provider_job_id)).map(&:exception_class),
            ready: SolidQueue::ReadyExecution.where(job_id: jobs.map(&:provider_job_id)).count,
            claimed: SolidQueue::ClaimedExecution.where(job_id: jobs.map(&:provider_job_id)).count }
        end
        end
        File.write(Rails.root.join("docs/evidence/#{ENV.fetch('RAILPRESS_EVIDENCE_MILESTONE', 'M06')}/#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-editorial-worker-deadline-#{SecureRandom.hex(3)}.json"), JSON.pretty_generate(state)+"\n")
        flunk "Native editorial worker timed out"
      end
      sleep 0.1
    end
    assert_equal 0, SolidQueue::FailedExecution.where(job_id: jobs.map(&:provider_job_id)).count
    puts "EDITORIAL_NATIVE_CLOCK_OBSERVATION: engine=#{ENV.fetch('RAILPRESS_TEST_ENGINE')} actual_worker=true duplicate_jobs=2 clock_held=#{held} status=#{item.reload.status} deadline_seconds=25"
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
    PublishContentJob.queue_adapter = original if original
    jobs&.each { |job| SolidQueue::Job.find_by(id: job.provider_job_id)&.destroy! }
  end

  test "actual native queue worker handles duplicate publication deliveries once" do
    item = scheduled_item
    run_duplicate_jobs(item)
    assert_equal "published", item.reload.status
    assert_equal 1, item.content_revisions.where(event: "scheduled_publish").count
    assert_includes item.published_snapshot["body"], "日本語"
  end

  test "actual native queue worker holds duplicate publication during a clock anomaly" do
    item = scheduled_item
    expected_version = item.lock_version
    clock = Railpress::SecurityClock.for_application
    clock.sample
    travel_to(Time.now + 5.seconds, with_usec: true) { clock.sample }
    assert clock.sample["anomaly"]
    run_duplicate_jobs(item, held: true)
    assert_equal "scheduled", item.reload.status
    assert_equal expected_version, item.lock_version
    assert_nil item.published_snapshot
    assert_equal 0, item.content_revisions.where(event: "scheduled_publish").count
    refute Content.publicly_visible.exists?(item.id)
    assert clock.sample["anomaly"], "Native worker must not clear the clock hold"
  end
end
