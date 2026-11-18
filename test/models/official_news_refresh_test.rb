require "test_helper"
require_relative "../support/official_news_test_support"
require_relative "../support/news_trace"
class OfficialNewsRefreshTest < ActiveSupport::TestCase
  include IdentityTestSupport
  include OfficialNewsTestSupport
  setup do
    install_site!
    @clock=Railpress::SecurityClock.new(File.join(@private_root, "news-cache-clock"))
    @client=NewsClientDouble.new(news_payload)
    @refresh=OfficialNews::Refresh.new(clock: @clock, client: @client)
    @row=OfficialNewsState.create!(site: Site.first, enabled: true, generation: 1)
    @news_trace=NewsTrace.new(self, @clock, @client, @refresh)
  end
  def capture_qualification_trace!
    @news_trace&.finish!(@private_root, @row)
  end
  def trusted_news_clock!
    # Protocol assertions need a known trusted interval; real-clock fencing is
    # separately exercised below. This changes no host time or security policy.
    @news_wall=Time.utc(2026, 11, 13, 12, 34, 56, 123456)
    travel_to(@news_wall, with_usec: true)
    @clock=Railpress::SecurityClock.new(File.join(@private_root, "trusted-protocol-clock"),
      elapsed: -> { 1000.0 }, domain: -> { "news-protocol-test-domain" })
    @refresh=OfficialNews::Refresh.new(clock: @clock, client: @client)
    @news_trace.watch_clock(@clock, "trusted_protocol")
    @news_trace.watch_refresh(@refresh)
  end
  test "default off and stale queued generations do not issue requests while successful data remains local" do
    @row.update!(enabled: false)
    @refresh.call(@row.id, 1)
    assert_equal 0, @client.calls
    @row.update!(enabled: true, generation: 2)
    @refresh.call(@row.id, 1)
    assert_equal 0, @client.calls
    @refresh.call(@row.id, 2)
    assert_equal 1, @client.calls
    assert_equal "FRESH", OfficialNews::Cache.view(@row.reload, clock: @clock)["state"]
    assert_equal news_payload, @row.payload
    @refresh.call(@row.id, 2)
    assert_equal 1, @client.calls
    refute_includes @client.headers.to_json, Site.first.install_id
    refute_includes @client.headers.to_json, @owner.email
  end
  test "bad remote data keeps last good cache records safe failure and uses bounded backoff" do
    @refresh.call(@row.id, 1)
    before=@row.reload.payload
    @row.update!(wait_binding: nil)
    @client.payload={ "schema_version"=>99, "items"=>[] }
    @refresh.call(@row.id, 1)
    assert_equal before, @row.reload.payload
    assert_equal "invalid_schema", @row.last_error
    assert_equal 1, @row.failures
    assert_equal "DEGRADED", OfficialNews::Cache.view(@row, clock: @clock)["state"]
    @refresh.call(@row.id, 1)
    assert_equal 2, @client.calls
    assert_operator @row.wait_binding["deadline"]-@row.wait_binding["issued_elapsed"], :<=, 300
  end
  test "not modified revalidates only an existing normalized cache and validators contain no injection" do
    trusted_news_clock!
    @news_trace.mark("trusted_protocol_start", @row)
    @client.status=304
    @refresh.call(@row.id, 1)
    assert_equal "invalid_not_modified", @row.reload.last_error
    assert_nil @row.payload
    @row.update!(wait_binding: nil)
    @client.status=200
    @refresh.call(@row.id, 1)
    @row.reload.update!(wait_binding: nil)
    original=@row.payload
    @news_trace.mark("after_200_before_final_304", @row)
    @client.status=304
    @refresh.call(@row.id, 1)
    assert_equal original, @row.reload.payload
    assert_nil @row.last_error
    assert_equal 3, @client.calls
    assert_equal '"synthetic-safe-etag"', @client.headers.last[:etag]
    assert_nil OfficialNews::Client.etag("\"safe\"\r\nAuthorization: secret")
    assert_nil OfficialNews::Client.modified("Fri, 13 Nov 2026 00:00:00 GMT\r\nX: secret")
  end
  test "opt out clears cache persists and prevents old queued refresh or saved results" do
    @refresh.call(@row.id, 1)
    @row.reload
    disabled=OfficialNews::Controls.call(actor: @owner, operation: "disable", version: @row.lock_version)
    assert_equal false, disabled.enabled
    assert_nil disabled.payload
    assert_nil disabled.etag
    @refresh.call(@row.id, 1)
    assert_equal 1, @client.calls
    assert_equal "DISABLED", OfficialNews::Cache.view(OfficialNewsState.find(@row.id), clock: @clock)["state"]
    assert_raises(OfficialNews::Controls::Conflict) { OfficialNews::Controls.call(actor: @owner, operation: "enable", version: 0) }
  end
  test "known wall discontinuities never label cache fresh or issue new external work" do
    @refresh.call(@row.id, 1)
    original=@row.reload.payload
    @row.update!(wait_binding: nil)
    travel_to(Time.current-5.seconds) do
      assert_equal "STALE", OfficialNews::Cache.view(@row, clock: @clock)["state"]
      @refresh.call(@row.id, 1)
      assert_equal 1, @client.calls
    end
    assert_equal original, @row.reload.payload
  end
  test "official canonical origin never fetches itself when provider mode is disabled" do
    Site.first.update!(canonical_origin: OfficialNews::Schema::ORIGIN, indexing_enabled: true)
    @client.failure="must_never_fetch_self"
    @refresh.call(@row.id, 1)
    assert_equal 0, @client.calls
    assert_equal "provider_disabled", @row.reload.last_error
    assert_equal "OFFLINE", OfficialNews::Cache.view(@row, clock: @clock)["state"]
  end
  test "local provider reads ordinary posts without calling any transport" do
    @row.update!(provider_enabled: true)
    Site.first.update!(canonical_origin: OfficialNews::Schema::ORIGIN, indexing_enabled: true)
    post=news_post;review(post)
    @client.failure="should_never_call"
    @refresh.call(@row.id, 1)
    assert_equal 0, @client.calls
    assert_equal 1, @row.reload.payload["items"].length
    assert_equal "LOCAL", OfficialNews::Cache.view(@row, clock: @clock)["state"]
  end
  test "observed forward expiration rollback domain replacement and long outages cannot revive fresh cache" do
    travel_to(Time.current, with_usec: true)
    base=Time.current
    ticks=1000.0;domain="news-test-domain"
    clock=Railpress::SecurityClock.new(File.join(@private_root, "expiry-clock"), elapsed: -> { ticks }, domain: -> { domain })
    refresh=OfficialNews::Refresh.new(clock: clock, client: @client)
    @news_trace.watch_clock(clock, "expiry_or_retention")
    @news_trace.watch_refresh(refresh)
    refresh.call(@row.id, 1)
    assert_equal "FRESH", OfficialNews::Cache.view(@row.reload, clock: clock)["state"]
    ticks+=OfficialNews::Cache::FRESH+1
    travel_to(base+OfficialNews::Cache::FRESH+1, with_usec: true) do
      assert_equal "STALE", OfficialNews::Cache.view(@row, clock: clock)["state"]
    end
    travel_to(base) { refute_equal "FRESH", OfficialNews::Cache.view(@row, clock: clock)["state"] }
    domain="replacement-domain"
    assert_empty OfficialNews::Cache.view(@row, clock: clock)["items"]
    assert_equal 1, @client.calls
  end
  test "expired retained metadata is cleared even if the next transport fails" do
    travel_to(Time.at(Time.now.to_i).utc+0.8, with_usec: true)
    base=Time.current;ticks=1000.0
    clock=Railpress::SecurityClock.new(File.join(@private_root, "retention-clock"), elapsed: -> { ticks }, domain: -> { "retention-domain" })
    refresh=OfficialNews::Refresh.new(clock: clock, client: @client)
    @news_trace.watch_clock(clock, "expiry_or_retention")
    @news_trace.watch_refresh(refresh)
    refresh.call(@row.id, 1)
    @client.failure="verified_provider_unavailable"
    ticks+=OfficialNews::Cache::RETAIN+2
    travel_to(base+OfficialNews::Cache::RETAIN+2, with_usec: true) do
      refresh.call(@row.id, 1)
      puts "NEWS_RETENTION_CLOCK_OBSERVATION: #{JSON.generate(anomaly: clock.sample['anomaly'], client_calls: @client.calls, retention_usable: OfficialNews::Cache.valid?(clock, @row.reload.retention_binding, OfficialNews::Cache::RETAIN))}"
      assert_nil @row.reload.payload
      assert_equal "verified_provider_unavailable", @row.last_error
      assert_empty OfficialNews::Cache.view(@row, clock: clock)["items"]
    end
  end
  test "concurrent refreshes serialize one fetch and opt out returns only after the active fetch is fenced" do
    started=Queue.new;finish=Queue.new;errors=Queue.new
    @client.hook=-> { started<<true;finish.pop }
    fetch=Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { @refresh.call(@row.id, 1) }
    rescue StandardError=>error
      errors<<error
    end
    Timeout.timeout(5) { started.pop }
    disable=Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        row=OfficialNewsState.find(@row.id)
        # Wait for the fetch commit, then use a freshly observed optimistic version.
        row.with_lock { }
        OfficialNews::Controls.call(actor: User.find(@owner.id), operation: "disable", version: row.reload.lock_version)
      end
    rescue StandardError=>error
      errors<<error
    end
    finish<<true;fetch.join;disable.join
    assert errors.empty?, errors.size.to_s
    assert_equal 1, @client.calls
    refute @row.reload.enabled
    assert_nil @row.payload
    @refresh.call(@row.id, 1)
    assert_equal 1, @client.calls
  end
  test "clock hold before revalidation preserves cache and never issues an unauthorized third request" do
    trusted_news_clock!
    @refresh.call(@row.id, 1)
    @row.reload.update!(wait_binding: nil)
    before=@row.payload
    assert_equal 1, @client.calls
    @client.status=304
    travel_to(@news_wall-2, with_usec: true) { @refresh.call(@row.id, 1) }
    assert @news_trace.held?
    assert_equal 1, @client.calls
    assert_nil @client.headers.last[:etag]
    assert_equal before, @row.reload.payload
    assert_equal '"synthetic-safe-etag"', @row.etag
    assert_nil @row.last_error
    assert_equal "STALE", OfficialNews::Cache.view(@row, clock: @clock)["state"]
    assert @news_trace.dispatches_authorized?
  end
  test "a hold arising in an already started response prevents freshness and the next request" do
    trusted_news_clock!
    @client.hook=-> { travel_to(@news_wall-2, with_usec: true) }
    @refresh.call(@row.id, 1)
    assert_equal 1, @client.calls
    assert @news_trace.held?
    assert_equal news_payload, @row.reload.payload
    assert_equal "STALE", OfficialNews::Cache.view(@row, clock: @clock)["state"]
    before=@row.payload
    @row.update!(wait_binding: nil)
    @client.hook=nil;@client.status=304
    @refresh.call(@row.id, 1)
    assert_equal 1, @client.calls
    assert_equal before, @row.reload.payload
    assert_nil @row.last_error
    assert @news_trace.dispatches_authorized?
  end
  test "actual clock integration retains every dispatch gate and fences an observed hold" do
    @refresh.call(@row.id, 1)
    @row.reload
    assert @news_trace.dispatches_authorized?
    if @client.calls.zero?
      assert @news_trace.held?, "trusted actual clock must not silently suppress the first request"
      assert_nil @row.payload
    else
      assert_equal 1, @client.calls
      assert_equal news_payload, @row.payload
      assert_nil @row.last_error
      @row.update!(wait_binding: nil);@client.status=304
      @refresh.call(@row.id, 1)
      assert @news_trace.dispatches_authorized?
      if @client.calls == 2
        assert_equal '"synthetic-safe-etag"', @client.headers.last[:etag]
        assert_equal news_payload, @row.reload.payload
        assert_nil @row.last_error
      else
        assert @news_trace.held?, "stable actual-clock revalidation must issue its validator request"
        assert_equal 1, @client.calls
      end
    end
  end
end
