require_relative "../../test/test_helper"
require_relative "../../test/support/editorial_test_support"
require_relative "../../test/support/public_request_observation"
class M08AliasProbeTest < ActionDispatch::IntegrationTest
  include EditorialTestSupport
  include PublicRequestObservation
  test "observe native publication cutoff through realtime steps without changing the host clock" do
    item = draft("Page", slug: "home", home_page: true)
    private_page = draft("Page", slug: "never-visible", visibility: "private", title: "PRIVATE ALIAS PROBE")
    change(private_page, "publish")
    rows = []; start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) - start < 38
      change(item, "unpublish") if item.reload.status == "published"
      change(item, "publish")
      approved_at = item.reload.published_at
      publication_clock = { realtime: Time.now.utc.iso8601(6), monotonic: Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      observed_public_get "/home"
      trace = @qualification_request_trace.deep_dup
      query = trace[:eligibility_queries].find { |entry| entry[:sql].include?("slug_key") }
      assert query, "Missing actual alias cutoff query"
      bound = query[:binds].find { |value| value.is_a?(String) && value.match?(/\A20\d\d-\d\d-\d\d[ T]/) }
      bound ||= query[:sql][/published_at\s*<=\s*'([^']+)'/, 1]
      File.write(Rails.root.join("docs/evidence/M08/#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-alias-probe-first-trace-v3.json"), JSON.pretty_generate(trace) + "\n") if rows.empty?
      assert bound, "Missing bound cutoff"
      cutoff = bound.include?("T") ? Time.iso8601(bound) : Time.parse(bound + " UTC")
      expected = cutoff >= approved_at ? 301 : 404
      assert_equal expected, response.status
      rows << { iteration: rows.length, published_at: approved_at.iso8601(6), cutoff: cutoff.utc.iso8601(6), status: response.status, publication_clock: publication_clock, trace: trace }
      if rows.length % 10 == 0
        get "/never-visible"; assert_response :not_found; refute_includes response.body, "PRIVATE ALIAS PROBE"
      end
    end
    result = { scope: "native clocks; original unconditional alias assertion unchanged; direct query cutoff evidence", host_clock_changed: false, iterations: rows.length,
      undercounts: rows.select { |row| row[:status] == 404 }, first: rows.first(3), last: rows.last(3) }
    File.write(Rails.root.join("docs/evidence/M08/#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-alias-native-probe-v3.json"), JSON.pretty_generate(result) + "\n")
  end
end
