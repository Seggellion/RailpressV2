require "test_helper"
require "vips"
require_relative "../support/portability_test_support"
class LegacyPortabilityTest < ActiveSupport::TestCase
  include IdentityTestSupport
  include PortabilityTestSupport
  setup { install_site! }
  def extraction
    { "format"=>"railpress.legacy_extract.v1", "source"=>SecureRandom.uuid, "site"=>portable_manifest["site"], "approved"=>{ "media"=>[], "sections"=>[] }, "blob_map"=>{}, "embedded_map"=>{},
      "pages"=>[ { "id"=>1, "user_id"=>nil, "title"=>"Legacy Page", "slug"=>"legacy-page", "published"=>true, "content"=>"<p>Ordinary content</p>" } ],
      "articles"=>[ { "id"=>42, "title"=>"Ordinary Article", "slug"=>"ordinary-article", "content"=>"<p>Article body</p>", "bnn"=>false, "owner_authored"=>false, "article_shards"=>[] }, { "id"=>43, "title"=>"FORBIDDEN BNN", "bnn"=>true }, { "id"=>44, "title"=>"FORBIDDEN SHARD", "article_shards"=>[ 7 ] }, { "id"=>45, "title"=>"FORBIDDEN OWNER GAME ARTICLE", "owner_authored"=>true } ],
      "posts"=>[ { "id"=>42, "title"=>"Ordinary Post", "content"=>"<p>Post body</p>" } ], "categories"=>[], "post_categories"=>[], "media"=>[], "sections"=>[], "blocks"=>[], "rich_texts"=>[], "attachments"=>[], "blobs"=>[] }
  end
  def decisions
    { "authors"=>{}, "records"=>%w[Page:1 Article:42 Post:42].to_h { |key| [ key, { "missing_dates"=>"preserve_unknown", "missing_author"=>"preserve_unassigned", "html"=>"sanitize", "slug"=>key == "Post:42" ? "ordinary-post" : key == "Page:1" ? "legacy-page" : "ordinary-article" } ] } }
  end
  test "missing dates authors and paths require actionable decisions; no game or account state migrates" do
    document = extraction
    result = Portability::Legacy::Adapter.new(document: document, decisions: {}, payloads: {}).call
    assert_nil result["archive"]
    assert result["report"]["conflicts"].any? { |c| c["code"] == "missing_author" }
    assert result["report"]["conflicts"].any? { |c| c["code"] == "missing_published_at" }
    assert result["report"]["conflicts"].any? { |c| c["code"] == "missing_slug" }
    approved = Portability::Legacy::Adapter.new(document: document, decisions: decisions, payloads: {}).call
    assert approved["archive"]
    assert_empty approved["report"]["conflicts"]
    assert_equal 3, approved["manifest"]["content"].length
    assert_equal 3, approved["report"]["excluded"].length
    assert_equal 3, approved["manifest"]["content"].map { |r| r["ref"] }.uniq.length
    approved["manifest"]["content"].each do |record|
      assert_nil record["working"]["author_ref"]
      assert_equal "UNASSIGNED", record["working"]["portable_metadata"]["authorship"]
      assert_nil record["history"]["created_at"]
      assert_nil record["history"]["published_at"]
    end
    refute_includes approved["archive"], "FORBIDDEN"
    document["users"] = [ { "id"=>1, "password_digest"=>"CANARY" } ]
    assert_raises(Portability::Format::Invalid) { Portability::Legacy::Adapter.new(document: document, decisions: decisions, payloads: {}).call }
  end
  test "ActionText missing blob associations hierarchy and malformed HTML remain explicit conflicts" do
    document = extraction
    document["pages"][0]["content"] = '<p>Hello<script>danger()</script><action-text-attachment sgid="never-resolve"></action-text-attachment>'
    document["categories"] = [ { "id"=>8, "name"=>"Synthetic child", "slug"=>"synthetic-child", "parent_id"=>2 } ]
    document["attachments"] = [ { "id"=>1, "record_type"=>"Page", "record_id"=>1, "name"=>"images", "blob_id"=>99 } ]
    result = Portability::Legacy::Adapter.new(document: document, decisions: decisions, payloads: {}).call
    assert_nil result["archive"]
    codes = result["report"]["conflicts"].map { |c| c["code"] }
    assert_includes codes, "hierarchy"
    assert_includes codes, "missing_action_text_media"
    assert_includes codes, "missing_blob_association"
    assert_empty Content.all
  end
  test "approved Sections preserve order and unknown block semantics require explicit reviewed native conversion" do
    document = extraction
    document["approved"]["sections"] = [ 9 ]
    document["sections"] = [ { "id"=>9, "name"=>"Synthetic section", "position"=>0, "body"=>"<p>Section introduction</p>", "template"=>"never execute" } ]
    document["blocks"] = [ { "id"=>11, "section_id"=>9, "position"=>1, "block_type"=>"json", "content"=>'{"opaque":"source semantics"}' }, { "id"=>10, "section_id"=>9, "position"=>0, "block_type"=>"rich_text", "content"=>"<p>Reviewed<script>danger()</script></p>" } ]
    choices = decisions
    choices["records"]["Page:1"]["sections"] = [ 9 ]
    choices["records"]["Page:1"].delete("html")
    blocked = Portability::Legacy::Adapter.new(document: document, decisions: choices, payloads: {}).call
    assert_nil blocked["archive"]
    assert_includes blocked["report"]["conflicts"].map { |c| c["code"] }, "block_html"
    assert_includes blocked["report"]["conflicts"].map { |c| c["code"] }, "unsupported_block"
    choices["records"]["Page:1"]["html"] = "sanitize"
    choices["records"]["Page:1"]["native_blocks"] = { "11"=>[ { "type"=>"heading", "level"=>2, "text"=>"Reviewed explicit JSON conversion" } ] }
    approved = Portability::Legacy::Adapter.new(document: document, decisions: choices, payloads: {}).call
    assert approved["archive"]
    blocks = approved["manifest"]["content"].find { |c| c["working"]["type"] == "Page" }["working"]["blocks"]
    assert_equal %w[paragraph paragraph heading], blocks.map { |b| b["type"] }
    assert_equal "<p>Section introduction</p>", blocks[0]["html"]
    refute_includes blocks[1]["html"], "script"
    assert_equal "Reviewed explicit JSON conversion", blocks[2]["text"]
    assert approved["report"]["explicit_changes"].any? { |c| c["change"] == "explicit_native_block_mapping" }
  end
  test "approved ActionText media and polymorphic associations require explicit placement conversion and stage privately" do
    document = extraction
    raw = Vips::Image.black(60, 30).new_from_image([ 36, 91, 120 ]).write_to_buffer(".png")
    asset = MediaLibrary::Upload.call(actor: @owner, io: StringIO.new(raw), filename: "synthetic.png", content_type: "image/png", attributes: { "title"=>"Synthetic legacy image", "alt_text"=>"Blue rectangle", "caption"=>"Approved caption", "license_notes"=>"Original synthetic work", "attribution"=>"Synthetic fixture" })
    media = { "ref"=>SecureRandom.uuid, "metadata"=>asset.attributes.slice(*MediaAsset::METADATA), "rights"=>{ "status"=>"cleared", "license"=>"Original synthetic fixture", "attribution"=>"Synthetic fixture" }, "width"=>60, "height"=>30,
      "display"=>{ "sha256"=>asset.sha256, "bytes"=>asset.blob.byte_size }, "thumbnail"=>{ "sha256"=>asset.thumbnail_sha256, "bytes"=>asset.thumbnail_blob.byte_size } }
    payloads = { "media/#{asset.sha256}.png"=>asset.blob.download, "media/#{asset.thumbnail_sha256}.png"=>asset.thumbnail_blob.download }
    document["approved"]["media"] = [ 7 ]
    document["media"] = [ { "id"=>7, "approved"=>true, "shard_id"=>nil, "portable"=>media } ]
    document["rich_texts"] = [ { "id"=>8, "record_type"=>"Page", "record_id"=>1, "name"=>"content", "body"=>'<p>Approved body</p><action-text-attachment sgid="opaque-map-only"></action-text-attachment>' } ]
    document["embedded_map"] = { "opaque-map-only"=>9 }; document["blob_map"] = { "9"=>7 }
    document["blobs"] = [ { "id"=>9, "filename"=>"synthetic.png", "content_type"=>"image/png", "byte_size"=>raw.bytesize, "checksum"=>"source-checksum-is-not-native-hash" } ]
    document["attachments"] = [ { "id"=>10, "record_type"=>"ActionText::RichText", "record_id"=>8, "name"=>"embeds", "blob_id"=>9 } ]
    choices = decisions
    blocked = Portability::Legacy::Adapter.new(document: document, decisions: choices, payloads: payloads).call
    assert_nil blocked["archive"]
    assert_includes blocked["report"]["conflicts"].map { |c| c["code"] }, "embedded_placement"
    choices["records"]["Page:1"]["embedded_placement"] = "append_blocks_with_loss"
    result = Portability::Legacy::Adapter.new(document: document, decisions: choices, payloads: payloads).call
    assert result["archive"]
    assert_equal 1, result["manifest"]["media"].length
    assert_equal 1, result["manifest"]["content"].first["working"]["blocks"].length
    batch, = stage_portable(result["manifest"], payloads: result["payloads"])
    assert_equal "staged", batch.state
    assert_equal 3, Content.count
    assert_empty Content.publicly_visible
    assert_equal asset.sha256, MediaAsset.find(batch.import_items.find_by!(kind: "media").target_id).sha256
    assert Content.all.all? { |c| c.portable_metadata.dig("review", "status") == "AWAITING DESTINATION EDITORIAL REVIEW" }
    assert result["report"]["explicit_changes"].any? { |c| c["loss"] == "embedded_media_appended_as_blocks" }
  end
  test "unknown or coerced game flags never qualify an ordinary Article" do
    document = extraction
    document["articles"] = [ { "id"=>42, "title"=>"Unknown flags", "slug"=>"unknown-flags", "bnn"=>"false", "owner_authored"=>false, "article_shards"=>[] } ]
    result = Portability::Legacy::Adapter.new(document: document, decisions: decisions, payloads: {}).call
    assert_nil result["archive"]
    assert result["report"]["conflicts"].any? { |c| c["code"] == "unknown_game_flags" }
  end
end
