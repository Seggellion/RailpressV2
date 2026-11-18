require "test_helper"
require_relative "../support/media_test_support"
require "railpress/theme_fixture"
require "railpress/theme_smoke"

class WorkerReliabilityTest < ActiveSupport::TestCase
  include MediaTestSupport

  def replace_worker(source)
    path = File.join(@private_root, "controlled-worker.rb")
    File.write(path, source, mode: "w", perm: 0o600)
    original = MediaLibrary::Processor.method(:worker_path)
    MediaLibrary::Processor.define_singleton_method(:worker_path) { path }
    yield
  ensure
    MediaLibrary::Processor.define_singleton_method(:worker_path, original) if original
  end

  test "image timeout retains owned process evidence after quarantine cleanup" do
    session = UserSession.issue!(@owner)
    page = draft("Page", actor: @owner, title: "Retained publication", slug: "retained-publication")
    change(page, "publish", actor: @owner)
    before = page.reload.published_snapshot
    error = nil
    replace_worker("sleep 60\n") do
      error = assert_raises(MediaLibrary::Upload::Rejected) { upload_media(actor: @owner) }
    end
    assert_match(/timeout/, error.message)
    assert_respond_to error, :diagnostic
    report = error.diagnostic
    assert_equal "image", report.fetch("worker")
    assert_equal "timeout", report.fetch("reason")
    assert_equal 5, report.dig("limits", "wall_seconds")
    assert_operator report.fetch("elapsed_seconds"), :>=, 5
    assert_operator report.fetch("pid"), :>, 0
    assert_raises(Errno::ECHILD) { Process.waitpid(report.fetch("pid"), Process::WNOHANG) }
    refute_includes JSON.generate(report), @private_root
    refute_includes JSON.generate(report), @owner.email
    assert_equal before, page.reload.published_snapshot
    assert UserSession.resolve(session)
    assert_equal 0, MediaAsset.count
    assert_equal "rejected", MediaUpload.order(:id).last.state
    record(report)
  end

  def record(report)
    milestone = ENV["RAILPRESS_EVIDENCE_MILESTONE"]
    return unless milestone&.match?(/\A[A-Za-z0-9_-]+\z/)
    directory = Rails.root.join("docs/evidence", milestone)
    FileUtils.mkdir_p(directory)
    File.write(directory.join("#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-worker-#{SecureRandom.hex(5)}.json"), JSON.pretty_generate(report), perm: 0o600)
  end

  test "serial and concurrent image workers produce identical bounded outputs" do
    bytes = image_bytes
    process = proc do |index|
      directory = File.join(@private_root, "decode-#{index}")
      Dir.mkdir(directory, 0o700)
      input = File.join(directory, "input")
      File.binwrite(input, bytes)
      result = MediaLibrary::Processor.run!(input, directory)
      [ result, %w[display.png thumb.png].map { |name| Digest::SHA256.file(File.join(directory, name)).hexdigest } ]
    end
    serial = 2.times.map { |i| process.call(i) }
    concurrent = 2.times.map { |i| Thread.new { process.call(i + 2) } }.map(&:value)
    (serial + concurrent).each { |value| assert_equal serial.first, value }
    assert_equal 80, serial.first.first["width"]
    assert_equal 40, serial.first.first["height"]
  end

  test "terminated image worker is reaped and does not publish partial media" do
    error = nil
    replace_worker("Process.kill('TERM', Process.pid)\n") do
      error = assert_raises(MediaLibrary::Upload::Rejected) { upload_media(actor: @owner) }
    end
    assert_equal 15, error.diagnostic.fetch("signal")
    assert error.diagnostic.fetch("reaped")
    assert_equal 0, MediaAsset.count
    assert_equal "rejected", MediaUpload.order(:id).last.state
    record(error.diagnostic)
    assert upload_media(actor: @owner).persisted?
  end

  test "worker output limit refuses before permanent media and retains numeric diagnostics" do
    error = nil
    replace_worker("File.open(File.join(ARGV[1], 'display.png'), 'wb') { |f| 13.times { f.write('x' * 1_048_576) } }\n") do
      error = assert_raises(MediaLibrary::Upload::Rejected) { upload_media(actor: @owner) }
    end
    report = error.diagnostic
    assert_equal MediaLibrary::Processor::OUTPUT_BYTES, report.dig("file_bytes", "display.png")
    if report["reason"] == "timeout"
      assert_equal 9, report["signal"]
      assert_operator report["elapsed_seconds"], :>=, MediaLibrary::Processor::WALL_SECONDS
    else
      assert report["signal"] == Signal.list.fetch("XFSZ") || report["exit_status"].to_i.nonzero?
    end
    assert report["reaped"]
    assert_equal 0, MediaAsset.count
    record(report)
  end

  test "theme wall deadline preserves process evidence without activating anything" do
    signer = OpenSSL::PKey.generate_key("ED25519")
    keys = { Digest::SHA256.hexdigest(signer.public_to_der) => signer.public_to_pem }
    directory = File.join(@private_root, "sleeping-theme")
    Railpress::ThemeFixture.build(directory, root: Rails.root, signer: signer, mutate: ->(manifest, path) {
      Railpress::ThemeFixture.replace(manifest, path, "templates/home.html.erb", "<% sleep 60 %>")
    })
    error = assert_raises(Railpress::ThemeSmoke::Rejected) do
      Railpress::ThemeSmoke.call(directory, keys: keys, root: Rails.root)
    end
    report = error.diagnostic.fetch(:process)
    assert_equal "production_smoke_timeout", report.fetch("reason")
    assert_equal 10, report.dig("limits", "wall_seconds")
    assert_equal 9, report.fetch("signal")
    assert report.fetch("reaped")
    assert_raises(Errno::ECHILD) { Process.waitpid(report.fetch("pid"), Process::WNOHANG) }
    assert_equal 0, ThemeInstallation.count
    record(report)
  end
end
