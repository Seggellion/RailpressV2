require "test_helper"
require "tmpdir"
require "openssl"
require "timeout"
require_relative "../support/official_news_test_support"
require_relative "../support/official_news_tls_support"
class OfficialNewsTransportTest < ActiveSupport::TestCase
  include OfficialNewsTestSupport
  include OfficialNewsTlsSupport
  test "actual TLS verifies fixed hostname peer and pinned IP without cookies proxies identity or telemetry" do
    previous=ENV["https_proxy"];ENV["https_proxy"]="http://127.0.0.1:1"
    tls_fixture("ok") do |guard, store, directory, _uri|
      response=OfficialNews::Client.new(guard: guard, cert_store: store).get(etag: '"prior"', last_modified: "Thu, 12 Nov 2026 00:00:00 GMT")
      assert_equal 200, response.status
      assert_equal news_payload, response.payload
      request=File.read(File.join(directory, "request"))
      assert_includes request, "User-Agent: Railpress-OfficialNews/1"
      assert_includes request, "If-None-Match: \"prior\""
      assert_includes request, "Accept-Encoding: identity"
      refute_match(/Cookie:|Authorization:|Referer:|X-Site|X-User/i, request)
      assert_match(/GET \/api\/public\/v1\/news.json HTTP/, request)
    end
  ensure
    ENV["https_proxy"]=previous
  end
  test "untrusted certificates and wrong peer host fail without weakening TLS" do
    tls_fixture("ok") { |guard, _store, _dir, _uri|assert_raises(OfficialNews::Client::Failure) { OfficialNews::Client.new(guard: guard).get } }
    tls_fixture("ok") do |guard, store, _directory, uri|
      uri.host="wrong.invalid"
      assert_raises(OfficialNews::Client::Failure) { OfficialNews::Client.new(guard: guard, cert_store: store).get }
    end
  end
  test "redirect oversized header body encoded and HTML responses are actually refused" do
    %w[redirect headers oversize encoded html].each do |mode|
      tls_fixture(mode) { |guard, store, _directory, _uri|assert_raises(OfficialNews::Client::Failure) { OfficialNews::Client.new(guard: guard, cert_store: store).get } }
    end
  end
  test "slow and continuously trickled responses obey read and total bounds" do
    %w[slow drip].each do |mode|
      tls_fixture(mode) do |guard, store, _directory, _uri|
        started=Process.clock_gettime(Process::CLOCK_MONOTONIC)
        error=assert_raises(OfficialNews::Client::Failure) { OfficialNews::Client.new(guard: guard, cert_store: store).get }
        assert_equal "bounded_timeout", error.message
        assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC)-started, :<, 6.5
      end
    end
  end
end
