require "test_helper"
require_relative "../support/release_test_support"

class NativeReleaseUpdatesTest < ActionDispatch::IntegrationTest
  include IdentityTestSupport
  include ReleaseTestSupport
  setup do
    install_site!
    release_setup
    @saved_env = ENV.to_h.slice("RAILPRESS_NATIVE_PUBLIC_STATUS", "RAILPRESS_DEPLOYMENT_ID", "RAILPRESS_RELEASE_PUBLIC_TRUST")
    ENV["RAILPRESS_NATIVE_PUBLIC_STATUS"] = File.join(@operator_root, "native-status.json")
    ENV["RAILPRESS_RELEASE_PUBLIC_TRUST"] = File.join(@operator_root, "trust.json")
    ENV["RAILPRESS_DEPLOYMENT_ID"] = SecureRandom.uuid
    @native_status = { "format" => "railpress.host-status.v1", "scope" => "isolated-synthetic-nginx-v1",
      "production_qualified" => false, "independent_utc_qualified" => false, "deployment_id" => ENV["RAILPRESS_DEPLOYMENT_ID"],
      "capabilities" => %w[preflight promote revert], "generation" => 3, "active_release" => "a" * 64, "previous_release" => "b" * 64,
      "observed_elapsed" => Railpress::SecurityClock.elapsed, "domain" => Railpress::SecurityClock.boot_domain }
    publish_native_status
  end
  teardown do
    %w[RAILPRESS_NATIVE_PUBLIC_STATUS RAILPRESS_DEPLOYMENT_ID RAILPRESS_RELEASE_PUBLIC_TRUST].each { |key| ENV[key] = @saved_env[key] }
    release_teardown
  end
  def publish_native_status
    envelope = { "statement" => @native_status, "signature" => signed(@native_status, @status_signer) }
    Railpress::Releases::Filesystem.atomic(ENV.fetch("RAILPRESS_NATIVE_PUBLIC_STATUS"), JSON.generate(envelope))
  end
  def host_receipt(request)
    statement = { "format" => "railpress.host-result.v1", "scope" => "isolated-synthetic-nginx-v1",
      "deployment_id" => ENV["RAILPRESS_DEPLOYMENT_ID"], "request_id" => request.request_key,
      "operation" => request.operation, "release_id" => request.release_digest, "revision" => 1, "generation" => 3,
      "state" => "FAILED_STAGED", "error" => "revert_not_retained_predecessor",
      "metadata" => {}, "history" => [ { "phase" => "REVERT_ELIGIBILITY_CHECK" }, { "phase" => "FAILED_STAGED", "detail" => "revert_not_retained_predecessor" } ] }
    { "statement" => statement, "signature" => signed(statement, @status_signer) }
  end
  test "native owner queues require CSRF and remain idempotent without executing host actions" do
    sign_in
    id = SecureRandom.uuid
    params = { request_id: id, release_id: @release_fixture["release_id"], operation: "promote" }
    post "/admin/updates/stage", params: params
    assert_response :unprocessable_entity
    params[:authenticity_token] = csrf_token_for(self, "/admin/updates")
    2.times { post "/admin/updates/stage", params: params; assert_response :see_other }
    assert_equal 1, ReleaseRequest.count
    assert_empty Dir.children(File.join(@operator_root, "staging"))
    request = ReleaseRequest.first
    receipt = host_receipt(request)
    2.times { ::Releases::Requests.accept!(request: request, receipt: receipt) }
    assert_equal 1, request.reload.receipt_revision
    get "/admin/updates"
    assert_response :ok
    assert_select "details ol li", text: "REVERT_ELIGIBILITY_CHECK"
    assert_includes response.body, "revert_not_retained_predecessor"
    refute_includes response.body, @status_signer.private_to_pem
    %w[deployment_id request_id release_id operation revision].each do |field|
      changed = Marshal.load(Marshal.dump(receipt))
      changed["statement"][field] = field == "revision" ? 2 : "wrong"
      changed["signature"] = signed(changed["statement"], @status_signer)
      request.update_columns(receipt: changed)
      assert_equal "UNVERIFIED", ::Releases::Requests.receipt_for(request.reload)["state"]
    end
  end
  test "stale wrong domain tampered revoked or writable observations fail closed" do
    assert_equal %w[preflight promote revert], ::Releases::HostStatus.operations
    @native_status["observed_elapsed"] -= 31
    publish_native_status
    assert_empty ::Releases::HostStatus.operations
    @native_status["observed_elapsed"] = Railpress::SecurityClock.elapsed
    @native_status["domain"] = "different-domain"
    publish_native_status
    assert_empty ::Releases::HostStatus.operations
    @native_status["domain"] = Railpress::SecurityClock.boot_domain
    publish_native_status
    File.chmod(0o666, ENV.fetch("RAILPRESS_NATIVE_PUBLIC_STATUS"))
    assert_empty ::Releases::HostStatus.operations
    File.chmod(0o600, ENV.fetch("RAILPRESS_NATIVE_PUBLIC_STATUS"))
    @trust["generation"] = 2
    @trust["revoked"] = [ Railpress::Releases.key_id(@status_signer) ]
    write_trust
    assert_empty ::Releases::HostStatus.operations
  end
  test "all non owners are denied native direct routes even when capabilities are verified" do
    %w[administrator editor author].each do |role|
      account = User.create!(username: "native-#{role}", email: "native-#{role}@example.invalid", role: role, password: IdentityTestSupport::PASSWORD, password_confirmation: IdentityTestSupport::PASSWORD)
      sign_in(self, account)
      get "/admin/updates"
      assert_response :forbidden
      %w[preflight promote revert].each do |operation|
        token = csrf_token_for(self, "/admin")
        post "/admin/updates/stage", params: { authenticity_token: token, request_id: SecureRandom.uuid, release_id: @release_fixture["release_id"], operation: operation }
        assert_response :forbidden
      end
      delete "/logout", params: { authenticity_token: csrf_token_for(self, "/admin") }
    end
    assert_empty ReleaseRequest.all
  end
end
