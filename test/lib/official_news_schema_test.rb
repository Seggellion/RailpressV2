require "test_helper"
require_relative "../support/official_news_test_support"
class OfficialNewsSchemaTest < ActiveSupport::TestCase
  include OfficialNewsTestSupport
  test "strict bounded metadata schema accepts only fixed canonical public Post URLs and public fields" do
    assert_equal news_payload, OfficialNews::Schema.parse(JSON.generate(news_payload))
    bad=[]
    bad<<news_payload.merge("schema_version"=>2)
    bad<<news_payload.merge("site_id"=>"private-local-identity")
    bad<<news_payload.merge("items"=>21.times.map { news_payload["items"].first })
    bad<<news_payload.merge("items"=>[ news_payload["items"].first, news_payload["items"].first ])
    [ "javascript:alert(1)", "http://railpress.org/blog/safe", "https://railpress.org/admin", "https://railpress.org/preview/1", "https://127.0.0.1/blog/safe", "https://evil.invalid/blog/safe", "https://railpress.org:444/blog/safe", "https://user:password@railpress.org/blog/safe", "https://railpress.org/blog/safe?token=secret", "https://railpress.org/blog/safe#private", "//railpress.org/blog/safe" ].each do |url|
      bad<<Marshal.load(Marshal.dump(news_payload)).tap { |p|p["items"][0]["url"]=url }
    end
    [ { "title"=>"<script>unsafe</script>" }, { "excerpt"=>"x"*501 }, { "published_at"=>"2026-02-31T00:00:00Z" }, { "modified_at"=>"not-a-date" }, { "title"=>"   " }, { "body"=>"private draft" }, { "email"=>"owner@private.invalid" } ].each do |change|
      bad<<Marshal.load(Marshal.dump(news_payload)).tap { |p|p["items"][0].merge!(change) }
    end
    bad.each { |payload|assert_raises(OfficialNews::Schema::Invalid) { OfficialNews::Schema.normalize(payload) } }
    [ "{broken", "["*20+"0"+"]"*20, " "* (OfficialNews::Schema::MAX_BYTES+1) ].each do |bytes|
      assert_raises(OfficialNews::Schema::Invalid) { OfficialNews::Schema.parse(bytes) }
    end
  end
  test "fixed provider guard rejects all private mixed and rebound answers before HTTP" do
    endpoint=OfficialNews::Schema::ENDPOINT
    %w[127.0.0.1 10.0.0.1 172.16.0.1 192.168.0.1 169.254.169.254 ::1 fc00::1 ::ffff:127.0.0.1].each do |ip|
      guard=Seo::HttpTargetGuard.new(origin: OfficialNews::Schema::ORIGIN, allowed_urls: [ endpoint ], resolver: ->(_) { [ ip ] })
      assert_raises(OfficialNews::Client::Failure) { OfficialNews::Client.new(guard: guard).get }
    end
    addresses=[ [ "8.8.8.8" ], [ "8.8.8.8", "127.0.0.1" ] ]
    guard=Seo::HttpTargetGuard.new(origin: OfficialNews::Schema::ORIGIN, allowed_urls: [ endpoint ], resolver: ->(_) { addresses.shift })
    assert_equal "8.8.8.8", guard.call(endpoint).ip_address
    assert_raises(Seo::HttpTargetGuard::UnsafeTarget) { guard.call(endpoint) }
  end
end
