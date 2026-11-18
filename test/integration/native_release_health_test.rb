require "test_helper"

class NativeReleaseHealthTest < ActionDispatch::IntegrationTest
  include IdentityTestSupport
  setup do
    install_site!
    @saved_native_env = %w[RAILPRESS_NATIVE_PROBE_TOKEN RAILPRESS_DEPLOYMENT_ID RAILPRESS_DEPLOYMENT_DIGEST].to_h { |key| [ key, ENV[key] ] }
  end
  teardown do
    @saved_native_env.each { |key, value| ENV[key] = value }
  end
  test "native probe requires its separate exact capability even for signed in owner" do
    ENV.delete("RAILPRESS_NATIVE_PROBE_TOKEN")
    get "/health/release"
    assert_response :not_found
    sign_in
    ENV["RAILPRESS_NATIVE_PROBE_TOKEN"] = "a" * 64
    get "/health/release", headers: { "X-Railpress-Probe" => "b" * 64 }
    assert_response :not_found
    get "/health/release", headers: { "X-Railpress-Probe" => "a" * 64 }
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal Railpress::Product::VERSION, body.dig("product", "version")
    assert_equal Site.first.install_id, body["installation_id"]
    assert_equal 2, body.dig("product", "security_clock")
    assert_equal 21, body["business_fingerprints"].length
    assert body["business_fingerprints"].values.all? { |value| value.match?(/\A[0-9a-f]{64}\z/) }
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_includes response.headers["X-Robots-Tag"], "noindex"
    refute_includes response.body, @owner.password_digest
    refute_includes response.body, ENV["RAILPRESS_NATIVE_PROBE_TOKEN"]
  end
  test "native health returns independently configured release identity without changing site data" do
    ENV["RAILPRESS_NATIVE_PROBE_TOKEN"] = "c" * 64
    ENV["RAILPRESS_DEPLOYMENT_ID"] = SecureRandom.uuid
    ENV["RAILPRESS_DEPLOYMENT_DIGEST"] = "d" * 64
    get "/health/release", headers: { "X-Railpress-Probe" => "c" * 64 }
    assert_response :ok
    first = JSON.parse(response.body)
    get "/health/release", headers: { "X-Railpress-Probe" => "c" * 64 }
    second = JSON.parse(response.body)
    assert_equal ENV["RAILPRESS_DEPLOYMENT_DIGEST"], first["release_id"]
    assert_equal ENV["RAILPRESS_DEPLOYMENT_ID"], first["deployment_id"]
    assert_equal first["business_fingerprints"], second["business_fingerprints"]
    assert_equal first["clock_binding"], second["clock_binding"]
    refute first["clock_anomaly"]
  end
end
