require "test_helper"
require_relative "../support/media_test_support"
class MediaRequestsTest < ActionDispatch::IntegrationTest
  include MediaTestSupport
  test "anonymous library and framework blob upload routes are closed" do
    get admin_media_assets_path
    assert_redirected_to "/login"
    post "/rails/active_storage/direct_uploads"
    assert_response :not_found
  end
  test "actual multipart upload metadata search and owner-scoped list work with CSRF" do
    sign_in(self, @author)
    token=csrf_token_for(self, new_admin_media_asset_path)
    file=Tempfile.new([ "synthetic", ".png" ])
    file.binmode;file.write(image_bytes);file.close
    upload=Rack::Test::UploadedFile.new(file.path, "image/png", true, original_filename: "studio.png")
    post admin_media_assets_path, params: { file: upload, media_asset: { title: "Native upload", alt_text: "Blue test studio", author_id: @owner.id }, authenticity_token: token }
    assert_response :see_other
    asset=MediaAsset.last
    assert_equal @author.id, asset.author_id
    get response.location
    assert_includes response.body, "Blue test studio"
    get admin_media_assets_path, params: { q: "Native" }
    assert_includes response.body, "Native upload"
    get private_media_file_path(asset, variant: "thumb")
    assert_response :success
    assert_equal "image/png", response.media_type
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
  ensure
    file&.unlink
  end
  test "missing CSRF and another author's direct metadata or file requests are denied" do
    asset=upload_media
    sign_in(self, @editor)
    Identity::ManageUsers.change_role!(actor: @owner, user: @editor, role: "author")
    sign_in(self, @editor)
    get admin_media_asset_path(asset)
    assert_response :forbidden
    get private_media_file_path(asset)
    assert_response :forbidden
    patch admin_media_asset_path(asset), params: { media_asset: { alt_text: "forged" } }
    assert_response :unprocessable_entity
    assert_equal "A synthetic blue studio", asset.reload.alt_text
  end
  test "public image routes require current visible content and a live reference" do
    asset=upload_media
    item=draft(blocks: [ { "type"=>"image", "media_id"=>asset.id } ])
    path=public_media_file_path(content_id: item.id, public_id: asset.public_id, variant: "display")
    get path
    assert_response :not_found
    change(item, "publish")
    get path
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    refute_includes response.headers.to_s, asset.blob.key
    change(item, "unpublish")
    get path
    assert_response :not_found
  end
  test "missing objects produce accessible content fallback without private blob paths" do
    asset=upload_media
    item=draft(blocks: [ { "type"=>"image", "media_id"=>asset.id } ])
    change(item, "publish")
    asset.blob.service.delete(asset.blob.key)
    get "/blog/#{item.slug}"
    assert_response :success
    assert_includes response.body, "Image unavailable"
    assert_includes response.body, "A synthetic blue studio"
    refute_includes response.body, asset.blob.key
    get public_media_file_path(content_id: item.id, public_id: asset.public_id, variant: "display")
    assert_response :not_found
  end
  test "preview images require the same actor session and expiring preview credential" do
    asset=upload_media
    item=draft(blocks: [ { "type"=>"image", "media_id"=>asset.id } ])
    sign_in(self, @author)
    token=csrf_token_for(self, edit_admin_content_path(item))
    post preview_admin_content_path(item), params: { authenticity_token: token }
    get response.location
    assert_response :success
    document=Nokogiri::HTML(response.body)
    image=document.at_css('main img[src^="/preview/"][src*="/media/"]')
    assert image, "Select the actual private content media, not a decorative core brand image"
    image=image["src"]
    get image
    assert_response :success
    assert_equal "image/png", response.media_type
    assert_equal asset.sha256, Digest::SHA256.hexdigest(response.body)
    other=ActionDispatch::Integration::Session.new(Rails.application);other.https!;other.get(image)
    File.write(Rails.root.join("docs/evidence", ENV.fetch("RAILPRESS_EVIDENCE_MILESTONE", "qualification"), "#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-preview-media-ownership.json"), JSON.pretty_generate(first_document_image: document.at_css("img")["src"], private_content_image: image, anonymous_status: other.response.status, authenticated_media_sha256: asset.sha256, scope: "synthetic preview credential remains session-bound; decorative public branding is not private media")+"\n")
    assert_equal 303, other.response.status
    travel 11.minutes do
      get image
      assert_response :not_found
    end
  end
  test "purge refusal and metadata escaping are visible through actual owner forms" do
    asset=upload_media(title: "<script>title</script>")
    draft(blocks: [ { "type"=>"image", "media_id"=>asset.id } ])
    sign_in(self, @owner)
    token=csrf_token_for(self, admin_media_asset_path(asset))
    refute_includes response.body, "<script>title</script>"
    delete admin_media_asset_path(asset), params: { authenticity_token: token }
    assert_response :conflict
    assert_includes response.body, "Purge refused"
    assert_equal "ready", asset.reload.state
  end
  test "export HTTP requires owner CSRF and explicit private selection" do
    draft(body: "<p>PRIVATE EXPORT BODY</p>")
    sign_in(self, @editor)
    get new_admin_export_path
    assert_response :forbidden
    sign_in(self, @owner)
    token=csrf_token_for(self, new_admin_export_path)
    post admin_exports_path
    assert_response :unprocessable_entity
    post admin_exports_path, params: { authenticity_token: token }
    assert_response :success
    assert_empty JSON.parse(response.body)["content"]
    post admin_exports_path, params: { authenticity_token: token, include_private: "1" }
    assert_response :success
    assert_includes response.body, "PRIVATE EXPORT BODY"
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  test "server block composer accepts typed fields and preserves order through genuine forms" do
    asset=upload_media
    item=draft
    sign_in(self, @author)
    token=csrf_token_for(self, edit_admin_content_path(item))
    patch admin_content_path(item), params: { version: item.lock_version, content: { blocks_present: "1", blocks: { "0"=>{ type: "image", media_id: asset.id, caption: "From the library" } } }, authenticity_token: token }
    assert_response :see_other
    assert_equal asset.id, item.reload.blocks.first["media_id"]
    token=csrf_token_for(self, edit_admin_content_path(item))
    patch admin_content_path(item), params: { version: item.lock_version, content: { add_block: "features" }, authenticity_token: token }
    assert_response :see_other
    assert_equal [ "image", "features" ], item.reload.blocks.map { |b|b["type"] }
    token=csrf_token_for(self, edit_admin_content_path(item))
    patch admin_content_path(item), params: { version: item.lock_version, move_block: "1:up", add_item: "1", authenticity_token: token }
    assert_response :unprocessable_entity
    assert_equal [ "image", "features" ], item.reload.blocks.map { |b|b["type"] }
    token=csrf_token_for(self, edit_admin_content_path(item))
    patch admin_content_path(item), params: { version: item.lock_version, move_block: "1:up", authenticity_token: token }
    assert_response :see_other
    assert_equal [ "features", "image" ], item.reload.blocks.map { |b|b["type"] }
  end
  test "malformed block operations return validation errors without changing content or references" do
    asset=upload_media
    item=draft(blocks: [ { "type"=>"image", "media_id"=>asset.id } ])
    sign_in(self, @author)
    before=item.attributes.slice("blocks", "lock_version", "media_details")
    refs=item.media_references.pluck(:stage, :media_asset_id).sort
    [ { remove_block: "invalid" }, { add_item: "999" }, { add_item: "-999" }, { remove_block: "999" } ].each do |operation|
      token=csrf_token_for(self, edit_admin_content_path(item))
      patch admin_content_path(item), params: operation.merge(version: item.lock_version, authenticity_token: token)
      assert_response :unprocessable_entity
      assert_equal before, item.reload.attributes.slice("blocks", "lock_version", "media_details")
      assert_equal refs, item.media_references.pluck(:stage, :media_asset_id).sort
    end
    assert_raises(ContentBlocks::Schema::Invalid) do
      ContentBlocks::Schema.normalize([ { "type"=>"features", "items"=>[ nil ] } ])
    end
  end
end
