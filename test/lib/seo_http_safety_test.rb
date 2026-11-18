require "test_helper"
class SeoHttpSafetyTest < ActiveSupport::TestCase
  ORIGIN="https://publisher.example.invalid"
  def guard(addresses, allowed: [ ORIGIN+"/safe" ])
    Seo::HttpTargetGuard.new(origin: ORIGIN, allowed_urls: allowed, resolver: ->(_) { addresses })
  end
  test "loopback private special multicast mapped and mixed DNS answers are refused" do
    %w[127.0.0.1 10.0.0.1 172.16.1.1 192.168.1.1 169.254.169.254 100.64.0.1 192.0.2.1 198.18.0.1 224.0.0.1 255.255.255.255 ::1 fc00::1 fe80::1 ::ffff:127.0.0.1 64:ff9b::7f00:1 2002:7f00:1:: 2001:db8::1].each do |ip|
      assert_raises(Seo::HttpTargetGuard::UnsafeTarget, ip) { guard([ ip ]).call(ORIGIN+"/safe") }
    end
    assert_raises(Seo::HttpTargetGuard::UnsafeTarget) { guard([ "8.8.8.8", "127.0.0.1" ]).call(ORIGIN+"/safe") }
    assert_equal "8.8.8.8", guard([ "8.8.8.8" ]).call(ORIGIN+"/safe").ip_address
    assert_equal "2001:4860:4860::8888", guard([ "2001:4860:4860::8888" ]).call(ORIGIN+"/safe").ip_address
  end
  test "origin credentials fragments nonstandard ports unsafe route and URL bounds reject before HTTP" do
    [ "http://publisher.example.invalid/safe", "https://evil.invalid/safe", "https://user:pass@publisher.example.invalid/safe", ORIGIN+":444/safe", ORIGIN+"/safe#x", ORIGIN+"/admin", ORIGIN+"/preview/1", ORIGIN+"/"+"a"*2100 ].each do |url|
      assert_raises(Seo::HttpTargetGuard::UnsafeTarget) { guard([ "8.8.8.8" ]).call(url) }
    end
    assert_raises(Seo::HttpTargetGuard::UnsafeTarget) { guard([]).call(ORIGIN+"/safe") }
  end
  test "DNS rebind after redirect cannot change pinned peer or contact private destination" do
    addresses=[ [ "8.8.8.8" ], [ "127.0.0.1" ] ]
    seen=[]
    resolver=->(_) { addresses.shift }
    safe_guard=Seo::HttpTargetGuard.new(origin: ORIGIN, allowed_urls: [ ORIGIN+"/safe", ORIGIN+"/other" ], resolver: resolver)
    client=Object.new
    client.define_singleton_method(:get) do |uri:, ip_address:|
      seen<<[ uri.to_s, ip_address ]
      Seo::NetHttpClient::Response.new(status: 302, headers: { "location"=>[ "/other" ] }, body: "")
    end
    result=Seo::HttpValidator.new(guard: safe_guard, client: client).call(ORIGIN+"/safe")
    assert_equal [ [ "#{ORIGIN}/safe", "8.8.8.8" ] ], seen
    assert_includes result["codes"], "private_address"
  end
  test "unexpected redirect host admin route loops and redirect limit never escape scope" do
    [ "https://evil.invalid/path", "/admin", "/safe" ].each do |location|
      calls=0
      client=Object.new
      client.define_singleton_method(:get) do |**|
        calls+=1
        Seo::NetHttpClient::Response.new(status: 302, headers: { "location"=>[ location ] }, body: "")
      end
      result=Seo::HttpValidator.new(guard: guard([ "8.8.8.8" ]), client: client).call(ORIGIN+"/safe")
      assert_equal 1, calls
      assert result["codes"].any?
    end
    paths=(0..4).map { |i|ORIGIN+"/path-#{i}" }
    count=0
    client=Object.new
    client.define_singleton_method(:get) do |**|
      count+=1
      Seo::NetHttpClient::Response.new(status: 302, headers: { "location"=>[ paths[count] ] }, body: "")
    end
    result=Seo::HttpValidator.new(guard: guard([ "8.8.8.8" ], allowed: paths), client: client).call(paths.first)
    assert_equal 4, count
    assert_includes result["codes"], "redirect_limit"
  end
  test "timeouts oversized payloads transport failure and missing metadata produce actionable codes" do
    [ [ Seo::NetHttpClient::TimeoutError, "timeout" ], [ Seo::NetHttpClient::ResponseTooLarge, "oversized_or_encoded_response" ], [ Seo::NetHttpClient::NetworkError, "network_unavailable" ] ].each do |error, code|
      client=Object.new
      client.define_singleton_method(:get) { |**|raise error }
      assert_includes Seo::HttpValidator.new(guard: guard([ "8.8.8.8" ]), client: client).call(ORIGIN+"/safe")["codes"], code
    end
    client=Object.new
    def client.get(**)
      Seo::NetHttpClient::Response.new(status: 200, headers: { "content-type"=>[ "text/html" ] }, body: '<html><meta name="robots" content="noindex"><link rel="canonical" href="https://evil.invalid"></html>')
    end
    codes=Seo::HttpValidator.new(guard: guard([ "8.8.8.8" ]), client: client).call(ORIGIN+"/safe")["codes"]
    assert_includes codes, "canonical_mismatch"
    assert_includes codes, "noindex_or_missing_robots"
    assert_includes codes, "structured_data_missing"
  end
  test "DNS timeout and overlarge answer sets fail with bounded resolution" do
    resolver=->(_) { sleep 4;[ "8.8.8.8" ] }
    checked=Seo::HttpTargetGuard.new(origin: ORIGIN, allowed_urls: [ ORIGIN+"/safe" ], resolver: resolver)
    started=Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error=assert_raises(Seo::HttpTargetGuard::UnsafeTarget) { checked.call(ORIGIN+"/safe") }
    assert_equal "dns_resolution_failed", error.message
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC)-started, :<, 3.5
    addresses=(1..17).map { |i|"8.8.8.#{i}" }
    assert_raises(Seo::HttpTargetGuard::UnsafeTarget) { guard(addresses).call(ORIGIN+"/safe") }
  end
end
