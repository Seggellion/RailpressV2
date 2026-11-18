require "test_helper"
require_relative "../support/gcs_test_support"

class GcsMediaRequestsTest < ActionDispatch::IntegrationTest
  include GcsTestSupport
  test "GCS public delivery follows committed publication and private delivery requires current authority" do
    asset = upload_media
    content = draft(blocks: [ { "type" => "image", "media_id" => asset.id } ])
    path = public_media_file_path(content_id: content.id, public_id: asset.public_id, variant: "display")
    get path
    assert_response :not_found
    get private_media_file_path(asset)
    assert_response :see_other
    change(content, "publish")
    get path
    assert_response :success
    assert_equal asset.sha256, Digest::SHA256.hexdigest(response.body)
    refute_includes response.headers.to_s, "synthetic-bucket"
    refute_includes response.headers.to_s, asset.blob.key
    sign_in(self, @author)
    get private_media_file_path(asset)
    assert_response :success
    change(content, "unpublish")
    get path
    assert_response :not_found
    refute Rails.application.config.active_storage.draw_routes
    assert_raises(Railpress::Gcs::Failure) { @service.url(asset.blob.key) }
  end
  test "cloud outage preserves accessible fallback without leaking provider secrets" do
    asset = upload_media
    content = draft(blocks: [ { "type" => "image", "media_id" => asset.id } ])
    change(content, "publish")
    @api.failure = Google::Cloud::PermissionDeniedError.new("synthetic-provider-secret")
    get "/blog/#{content.slug}"
    assert_response :success
    assert_includes response.body, "Image unavailable"
    refute_includes response.body, "synthetic-provider-secret"
    refute_includes response.body, asset.blob.key
    get public_media_file_path(content_id: content.id, public_id: asset.public_id, variant: "display")
    assert_response :not_found
  end
  test "provider upload failure gives accessible protected service-unavailable feedback and retains cleanup journal" do
    sign_in(self, @author)
    csrf = csrf_token_for(self, new_admin_media_asset_path)
    file = Tempfile.new([ "gcs-upload", ".png" ], @private_root)
    begin
      file.binmode
      file.write(image_bytes)
      file.flush
      upload = Rack::Test::UploadedFile.new(file.path, "image/png")
      @api.failure = Google::Cloud::PermissionDeniedError.new("synthetic-provider-secret")
      post admin_media_assets_path, params: { authenticity_token: csrf, file: upload, media_asset: { title: "Synthetic", alt_text: "Synthetic image" } }
      assert_response :service_unavailable
      assert_includes response.body, "Media storage is unavailable"
      refute_includes response.body, "synthetic-provider-secret"
      assert_equal 0, MediaAsset.count
      assert_equal 2, MediaUpload.last.storage_keys.length
      assert_equal "no-store", response.headers["Cache-Control"]
    ensure
      file.close!
    end
  end
  test "logical purge notice accurately discloses retained backup bytes" do
    asset = upload_media
    before = @api.fingerprint
    sign_in(self, @author)
    csrf = csrf_token_for(self, admin_media_asset_path(asset))
    delete admin_media_asset_path(asset), params: { authenticity_token: csrf }
    assert_response :see_other
    follow_redirect!
    assert_response :success
    assert_includes response.body, "Stored files are retained for backups."
    assert_equal "purged", asset.reload.state
    assert_equal before, @api.fingerprint
  end
end
