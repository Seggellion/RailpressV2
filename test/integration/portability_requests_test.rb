require "test_helper"
require_relative "../support/portability_test_support"
class PortabilityRequestsTest < ActionDispatch::IntegrationTest
  include IdentityTestSupport
  include PortabilityTestSupport
  setup { install_site! }
  test "Owner upload inspection review approval and truthful progress use protected native jobs" do
    previous_adapter = PortabilityImportJob.queue_adapter
    PortabilityImportJob.queue_adapter = :solid_queue
    sign_in
    token = csrf_token_for(self, "/admin/imports")
    assert_response :success
    assert_select "h1", "Import / Export"
    assert_select 'form[enctype="multipart/form-data"]'
    assert_select 'select[name="mode"] option[selected]', count: 0
    manifest = portable_manifest
    bytes = Railpress::SiteArchive.build(manifest, {})
    Tempfile.create([ "archive", ".railpress" ], @private_root) do |file|
      file.binmode; file.write(bytes); file.flush
      post "/admin/imports", params: { authenticity_token: token, idempotency_key: SecureRandom.hex(32), archive: Rack::Test::UploadedFile.new(file.path, "application/octet-stream") }
    end
    assert_response :see_other
    batch = ImportBatch.last
    assert_equal "queued", batch.state
    assert SolidQueue::Job.where(class_name: "PortabilityImportJob").exists?
    PortabilityImportJob.perform_now(batch.id)
    assert_equal "review", batch.reload.state
    token = csrf_token_for(self, "/admin/imports/#{batch.public_id}")
    assert_response :success
    assert_select "h2", text: "Dry-run inventory"
    assert_select "pre", text: manifest["content"][0]["working"]["body"]
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_includes response.headers["X-Robots-Tag"], "noindex"
    decisions = portable_decisions(manifest)
    post "/admin/imports/#{batch.public_id}/approve", params: { authenticity_token: token, version: batch.lock_version, decisions: decisions }
    assert_response :see_other
    PortabilityImportJob.perform_now(batch.id)
    assert_equal "staged", batch.reload.state
    get "/admin/imports/#{batch.public_id}/status", headers: { "Accept"=>"application/json" }
    assert_response :success
    assert_equal({ "state"=>"staged", "progress"=>1, "total"=>1, "failure"=>nil }, response.parsed_body)
    refute_includes response.body, manifest["content"][0]["working"]["body"]
    get "/admin/imports/#{batch.public_id}"
    assert_select "h2", "Reversal eligibility"
    assert_select "button", "Approve safe batch reversal"
  ensure
    PortabilityImportJob.queue_adapter = previous_adapter if previous_adapter
  end
  test "all nonOwner roles are denied import export history progress and direct mutations" do
    batch, = stage_portable(portable_manifest)
    %w[administrator editor author].each do |role|
      account = create_account(role)
      client = ActionDispatch::Integration::Session.new(Rails.application); client.https!
      sign_in(client, account)
      [ "/admin/imports", "/admin/imports/#{batch.public_id}", "/admin/imports/#{batch.public_id}/status" ].each do |path|
        client.get(path); assert_equal 403, client.response.status
        refute_includes client.response.body, "Portable"
      end
      csrf = csrf_token_for(client, "/admin")
      %w[approve activate retry reverse_batch inspect_archive cleanup preview_appearance].each do |action|
        client.post("/admin/imports/#{batch.public_id}/#{action}", params: { authenticity_token: csrf, version: batch.lock_version })
        assert_equal 403, client.response.status
      end
      client.post("/admin/site_exports", params: { authenticity_token: csrf, mode: "public" })
      assert_equal 403, client.response.status
    end
    assert_equal "staged", batch.reload.state
  end
  test "missing CSRF and arbitrary archive paths cannot invoke import" do
    sign_in
    post "/admin/imports", params: { archive: "/etc/passwd", idempotency_key: SecureRandom.hex(32) }
    assert_response :unprocessable_entity
    assert_empty ImportBatch.all
    csrf = csrf_token_for(self, "/admin/imports")
    post "/admin/imports", params: { authenticity_token: csrf, archive: "/etc/passwd", idempotency_key: SecureRandom.hex(32) }
    assert_response :unprocessable_entity
    assert_select '[role="alert"]', text: /Choose a .railpress archive/
    assert_empty ImportBatch.all
  end
end
