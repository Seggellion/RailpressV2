require "test_helper"
require_relative "../support/release_test_support"

class ReleaseUpdatesTest < ActionDispatch::IntegrationTest
  include IdentityTestSupport
  include ReleaseTestSupport
  setup do
    install_site!
    release_setup
    @previous_release_trust = ENV["RAILPRESS_RELEASE_PUBLIC_TRUST"]
    ENV["RAILPRESS_RELEASE_PUBLIC_TRUST"] = File.join(@operator_root, "trust.json")
  end
  teardown do
    ENV["RAILPRESS_RELEASE_PUBLIC_TRUST"] = @previous_release_trust
    release_teardown
  end

  test "owner requests are bounded audited idempotent and do not run native code in web process" do
    sign_in
    get "/admin/updates"
    assert_response :ok
    assert_includes response.body, Railpress::Product::VERSION
    assert_includes response.body, "UTC qualification: UNKNOWN"
    token = csrf_token_for(self, "/admin/updates")
    id = SecureRandom.uuid
    params = { authenticity_token: token, commit: "Queue operator request", utf8: "✓", request_id: id, release_id: @release_fixture["release_id"], operation: "stage" }
    2.times { post "/admin/updates/stage", params: params; assert_response :see_other }
    assert_equal 1, ReleaseRequest.count
    assert_equal 1, ActivityEvent.where(action: "release.requested").count
    assert_empty Dir.children(File.join(@operator_root, "staging"))
    get "/admin/updates"
    assert_includes response.body, "QUEUED"
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_includes response.headers["X-Robots-Tag"], "noindex"
    assert_equal Railpress::Product::VERSION, @operator.status["installed"]["version"]
  end

  test "signed operator result displays safe metadata and preserves active identities" do
    sign_in
    id = SecureRandom.uuid
    request = ::Releases::Requests.submit!(actor: @owner, operation: "stage", release_id: @release_fixture["release_id"], request_id: id)
    receipt = stage_release(id)
    ::Releases::Requests.accept!(request: request, receipt: receipt)
    get "/admin/updates"
    assert_response :ok
    assert_includes response.body, "STAGED"
    assert_includes response.body, "Operator signature verified"
    assert_includes response.body, "not a public distribution"
    assert_includes response.body, "Activation remains unsupported"
    refute_includes response.body, @release_signer.private_to_pem
    assert_equal @owner.id, Site.first.owner_id
    assert_nil ThemeState.first
    assert_equal Railpress::Product::VERSION, @operator.status["installed"]["version"]
  end

  test "tampered stale wrong purpose or wrong request receipts never become trusted UI state" do
    id = SecureRandom.uuid
    request = ::Releases::Requests.submit!(actor: @owner, operation: "stage", release_id: @release_fixture["release_id"], request_id: id)
    receipt = stage_release(id)
    ::Releases::Requests.accept!(request: request, receipt: receipt)
    assert_raises(ArgumentError) { ::Releases::Requests.accept!(request: request, receipt: receipt) }
    changed = Marshal.load(Marshal.dump(receipt))
    changed["statement"]["revision"] += 1
    changed["statement"]["state"] = "ACTIVE"
    assert_raises(ArgumentError) { ::Releases::Requests.accept!(request: request, receipt: changed) }
    assert_equal "STAGED", ::Releases::Requests.receipt_for(request.reload)["state"]
    request.update_columns(receipt: changed, receipt_revision: changed["statement"]["revision"])
    assert_equal "UNVERIFIED", ::Releases::Requests.receipt_for(request.reload)["state"]
    sign_in
    get "/admin/updates"
    assert_includes response.body, "UNVERIFIED"
    refute_includes response.body, "<strong>ACTIVE</strong>"
  end

  test "revoked publisher does not retain a trusted staged status in the UI" do
    id = SecureRandom.uuid
    request = ::Releases::Requests.submit!(actor: @owner, operation: "stage", release_id: @release_fixture["release_id"], request_id: id)
    ::Releases::Requests.accept!(request: request, receipt: stage_release(id))
    @trust["generation"] = 2
    @trust["revoked"] = [ Railpress::Releases.key_id(@release_signer) ]
    write_trust
    assert_equal "UNVERIFIED", ::Releases::Requests.receipt_for(request.reload)["state"]
    sign_in
    get "/admin/updates"
    assert_includes response.body, "UNVERIFIED"
    refute_includes response.body, "Native staging compatibility and file verification passed"
  end

  test "all non owners are denied direct requests and CSRF arbitrary paths commands and activation are refused" do
    %w[administrator editor author].each do |role|
      user = create_account(role)
      sign_in(self, user)
      get "/admin/updates"
      assert_response :forbidden
      token = csrf_token_for(self, "/admin")
      %w[inspect stage cancel promote revert shell].each do |op|
        post "/admin/updates/stage", params: { authenticity_token: token, operation: op, release_id: @release_fixture["release_id"], request_id: SecureRandom.uuid }
        assert_response :forbidden
      end
    end
    sign_in
    post "/admin/updates/stage", params: { operation: "stage", release_id: @release_fixture["release_id"], request_id: SecureRandom.uuid }
    assert_response :unprocessable_entity
    token = csrf_token_for(self, "/admin/updates")
    [ { operation: "promote" }, { operation: "revert" }, { release_id: "../etc/passwd" }, { request_id: "$(id)" },
      { command: "touch /tmp/unsafe" }, { url: "http://127.0.0.1/" }, { path: "/etc/passwd" } ].each do |mutation|
      post "/admin/updates/stage", params: { authenticity_token: token, operation: "stage", release_id: @release_fixture["release_id"], request_id: SecureRandom.uuid }.merge(mutation)
      assert_response :unprocessable_entity
    end
    assert_equal 0, ReleaseRequest.count
    assert_empty Dir.children(File.join(@operator_root, "staging"))
  end

  test "cancellation progress needs no publisher or package trust and remains verifiable" do
    id = SecureRandom.uuid
    request = ::Releases::Requests.submit!(actor: @owner, operation: "cancel", release_id: @release_fixture["release_id"], request_id: id)
    @operator = new_operator(progress: ->(receipt) { ::Releases::Requests.accept!(request: request, receipt: receipt) })
    receipt = @operator.cancel(request_id: id, release_id: @release_fixture["release_id"])
    ::Releases::Requests.accept!(request: request, receipt: receipt)
    assert_equal "CANCELLED", ::Releases::Requests.receipt_for(request.reload)["state"]
    assert_operator request.receipt_revision, :>=, 3
    sign_in
    get "/admin/updates"
    assert_includes response.body, "Native staging progress and journal history"
    assert_includes response.body, "CANCELLED"
  end

  test "world writable public trust cannot verify a staged status" do
    id = SecureRandom.uuid
    request = ::Releases::Requests.submit!(actor: @owner, operation: "stage", release_id: @release_fixture["release_id"], request_id: id)
    ::Releases::Requests.accept!(request: request, receipt: stage_release(id))
    File.chmod(0o666, File.join(@operator_root, "trust.json"))
    assert_equal "UNVERIFIED", ::Releases::Requests.receipt_for(request.reload)["state"]
    sign_in
    get "/admin/updates"
    assert_response :ok
    assert_includes response.body, "UNVERIFIED"
  end

  test "offline or corrupt status trust never blocks login editing or public rendering" do
    ENV["RAILPRESS_RELEASE_PUBLIC_TRUST"] = File.join(@operator_root, "not-present.json")
    sign_in
    get "/admin/updates"
    assert_response :ok
    get "/admin/contents?kind=Page"
    assert_response :ok
    get "/"
    assert_response :ok
    assert_equal 0, ReleaseRequest.count
  end

  test "concurrent submissions use one immutable request and conflict on reused identity" do
    id = SecureRandom.uuid
    errors = Queue.new
    gate = Queue.new
    workers = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          actor = User.find(@owner.id)
          gate.pop
          ::Releases::Requests.submit!(actor: actor, operation: "inspect", release_id: @release_fixture["release_id"], request_id: id)
        rescue StandardError => error
          errors << error
        end
      end
    end
    2.times { gate << true }
    workers.each(&:join)
    assert errors.empty?, errors.size.to_s
    assert_equal 1, ReleaseRequest.count
    assert_raises(ArgumentError) { ::Releases::Requests.submit!(actor: @owner, operation: "stage", release_id: @release_fixture["release_id"], request_id: id) }
    assert_equal "inspect", ReleaseRequest.first.operation
  end
end
