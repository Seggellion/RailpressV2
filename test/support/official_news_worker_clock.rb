# Explicit test-process clock fixture. Never loaded by application configuration.
require_relative "../../config/environment"
module OfficialNewsWorkerClock
  module_function
  def install!(directory)
    raise "Synthetic test process only" unless Rails.env.test? && ENV["RAILPRESS_TEST_CONFIRM"]=="railpress-synthetic-only"
    target=Railpress::TestDatabase.load!(root: Rails.root, engine: ENV.fetch("RAILPRESS_TEST_ENGINE"))
    Railpress::TestDatabase.verify!(target)
    path=File.realpath(directory)
    base=Rails.root.join(".local/state/m02-tests", ENV.fetch("RAILPRESS_TEST_ENGINE")).realpath.to_s
    stat=File.stat(path)
    raise "Exact private clock fixture required" unless path.start_with?(base+"/") && stat.uid==Process.uid && (stat.mode&0o077).zero?
    file=File.join(path, "anchor.json");stat=File.lstat(file)
    raise "Private clock anchor required" unless stat.file? && !stat.symlink? && stat.uid==Process.uid && (stat.mode&0o077).zero? && stat.size<=4096
    anchor=JSON.parse(File.read(file))
    raise "Clock fixture format" unless anchor.is_a?(Hash) && anchor.keys.sort==%w[domain elapsed format wall] && anchor["format"]=="railpress.test-news-clock.v1" &&
      %w[wall elapsed].all? { |key|anchor[key].is_a?(Numeric) && anchor[key].finite? } &&
      anchor["domain"]==Railpress::SecurityClock.boot_domain && (Railpress::SecurityClock.elapsed-anchor["elapsed"]).between?(0, 60)
    original_now=Time.method(:now)
    original_factory=Railpress::SecurityClock.method(:for_application)
    # Matching wall/elapsed sources in both processes. Real BOOTTIME deadlines,
    # certificate checks and host realtime remain unchanged. This is not UTC proof.
    Time.define_singleton_method(:now) do |**options|
      value=Time.at(anchor["wall"]+Railpress::SecurityClock.elapsed-anchor["elapsed"]).utc
      options[:in] ? value.getlocal(options[:in]) : value
    end
    clock=Railpress::SecurityClock.new(File.join(path, "authority"))
    Railpress::SecurityClock.define_singleton_method(:for_application) { clock }
    -> {
      Time.define_singleton_method(:now, original_now)
      Railpress::SecurityClock.define_singleton_method(:for_application, original_factory)
    }
  end
end
OfficialNewsWorkerClock.install!(ENV.fetch("RAILPRESS_NEWS_CLOCK_FIXTURE")) if ENV["RAILPRESS_NEWS_CLOCK_FIXTURE"]
