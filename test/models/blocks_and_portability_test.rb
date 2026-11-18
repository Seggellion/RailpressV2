require "test_helper"
require_relative "../support/media_test_support"
class BlocksAndPortabilityTest < ActiveSupport::TestCase
  include MediaTestSupport
  test "all block fixtures render semantic safe content with validated media" do
    asset = upload_media
    blocks = ContentBlocks::Schema::TYPES.map do |type|
      block = ContentBlocks::Schema.blank(type)
      block["text"] = "<script>escaped plain text</script>" if type == "heading"
      block["html"] = '<p>Hello <em>日本語</em></p><script>x()</script><img onerror="x()">' if type == "paragraph"
      block["media_id"] = asset.id if %w[image hero].include?(type)
      block["media_ids"] = [ asset.id ] if type == "gallery"
      block
    end
    item = draft(blocks: blocks, featured_media_id: asset.id)
    change(item, "publish")
    html = ContentPresenter.new(item).blocks_html
    document = Nokogiri::HTML.fragment(html)
    assert_equal 0, document.css("script,iframe,form").length
    assert_equal 3, document.css("img").length
    assert_equal 1, document.css("address").length
    assert_operator document.css("details").length, :>, 0
    assert_includes html, "日本語"
    refute_includes html, "onerror"
    assert_includes html, 'alt="A synthetic blue studio"'
    assert item.media_references.exists?(stage: "live", media_asset_id: asset.id)
    assert_equal 1, MediaReference.where(content_revision_id: item.content_revisions.first.id).count
  end
  test "unsupported executable blocks links overlarge data and foreign asset selection reject atomically" do
    assert_raises(ContentBlocks::Schema::Invalid) { draft(blocks: [ { "type"=>"erb", "text"=>"<%=system('x')%>" } ]) }
    %w[javascript:alert(1) data:text/html,x //evil.invalid https://user:pass@evil.invalid].each do |url|
      assert_raises(ContentBlocks::Schema::Invalid) { draft(blocks: [ { "type"=>"call_to_action", "url"=>url } ]) }
    end
    assert_raises(ContentBlocks::Schema::Invalid) { draft(blocks: Array.new(41) { { "type"=>"heading" } }) }
    foreign = upload_media(actor: @editor)
    assert_raises(Identity::Capabilities::Denied) { draft(blocks: [ { "type"=>"image", "media_id"=>foreign.id } ]) }
    assert_equal 0, Content.count
  end
  test "working image metadata and blocks never silently alter live snapshots" do
    asset = upload_media
    item = draft(blocks: [ { "type"=>"image", "media_id"=>asset.id } ], featured_media_id: asset.id)
    change(item, "publish")
    MediaLibrary::Manage.update!(actor: @author, asset: asset, attributes: { "alt_text"=>"Unpublished alternative" }, version: asset.lock_version)
    change(item, actor: @author, attributes: { "blocks"=>[ { "type"=>"image", "media_id"=>asset.id } ] })
    assert_equal "A synthetic blue studio", item.published_snapshot["media_details"][asset.id.to_s]["alt_text"]
    assert_equal "Unpublished alternative", item.media_details[asset.id.to_s]["alt_text"]
    assert_includes ContentPresenter.new(item).blocks_html, "A synthetic blue studio"
    change(item, "publish")
    assert_includes ContentPresenter.new(item).blocks_html, "Unpublished alternative"
  end
  test "revision restore retains immutable media and removes current public visibility" do
    asset=upload_media
    item=draft(blocks: [ { "type"=>"image", "media_id"=>asset.id } ])
    original=item.content_revisions.first
    change(item, "publish")
    change(item, attributes: { "blocks"=>[] })
    assert_raises(MediaLibrary::Manage::InUse) { MediaLibrary::Manage.purge!(actor: @author, asset: asset) }
    change(item, "restore_revision", revision: original.id)
    assert_equal asset.id, item.blocks.first["media_id"]
    assert_nil item.published_snapshot
    assert_equal "draft", item.status
  end
  test "default export contains only approved public snapshots and checksum media references" do
    asset=upload_media
    item=draft(blocks: [ { "type"=>"image", "media_id"=>asset.id } ], body: "<p>PUBLIC COPY</p>")
    change(item, "publish")
    change(item, attributes: { "body"=>"<p>PRIVATE WORKING COPY</p>" })
    draft(slug: "private-draft", body: "<p>PRIVATE DRAFT</p>")
    payload=Portability::Export.call(actor: @owner)
    json=JSON.generate(payload)
    assert Portability::Validate.call(json)
    assert_includes json, "PUBLIC COPY"
    refute_includes json, "PRIVATE WORKING COPY"
    refute_includes json, "PRIVATE DRAFT"
    [ @owner.email, @owner.password_digest, asset.blob.key, Site.first.install_id ].each { |secret|refute_includes json, secret }
    assert_equal false, payload["media_payloads_included"]
    assert_equal asset.sha256, payload["content"].first["blocks"].first["media_ref"]
    assert_equal 1, payload["revision_hashes"].length
    assert_empty payload["menus"]
    assert_empty payload["redirects"]
    File.write(Rails.root.join("docs/evidence/#{ENV.fetch('RAILPRESS_EVIDENCE_MILESTONE', 'M06')}/#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-public-manifest.json"), JSON.pretty_generate(payload)+"\n")
  end
  test "private export is owner explicit and still excludes authentication records" do
    draft(body: "<p>EXPLICIT PRIVATE COPY</p>")
    assert_raises(Identity::Capabilities::Denied) { Portability::Export.call(actor: @editor, include_private: true) }
    json=JSON.generate(Portability::Export.call(actor: @owner, include_private: true))
    assert_includes json, "EXPLICIT PRIVATE COPY"
    assert Portability::Validate.call(json)
    File.write(Rails.root.join("docs/evidence/#{ENV.fetch('RAILPRESS_EVIDENCE_MILESTONE', 'M06')}/#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-private-fixture-manifest.json"), json+"\n")
    refute_match(/password_digest|auth_version|token_digest|storage_key|smtp/, json)
  end
  test "import contract rejects unsupported versions credential fields unsafe paths and unknown references" do
    asset=upload_media
    item=draft(blocks: [ { "type"=>"image", "media_id"=>asset.id } ])
    change(item, "publish")
    payload=Portability::Export.call(actor: @owner)
    mutations=[
      ->(x) { x["format_version"]=99 },
      ->(x) { x["extensions"]["password"]="forbidden" },
      ->(x) { x["media"][0]["file"]="../../secrets" },
      ->(x) { x["content"][0]["blocks"][0]["media_ref"]="f"*64 },
      ->(x) { x["content"][0]["blocks"][0]["template"]="../../etc" },
      ->(x) { x["site"]["canonical_origin"]="http://insecure.invalid" },
      ->(x) { x["menus"]=[ { "unimplemented"=>true } ] }
    ]
    mutations.each do |mutation|
      copy=payload.deep_dup;mutation.call(copy)
      assert_raises(Portability::Validate::Invalid) { Portability::Validate.call(JSON.generate(copy)) }
    end
  end
  test "starter patterns and decorative images have no contact form or executable content" do
    asset=upload_media(decorative: true, alt_text: "")
    item=draft(blocks: ContentBlocks::Patterns.fetch("contact")+[ { "type"=>"image", "media_id"=>asset.id } ])
    change(item, "publish")
    html=ContentPresenter.new(item).blocks_html
    assert_includes html, 'alt=""'
    refute_match(/<form|<script|<iframe/, html)
    assert_includes html, "Contact details"
  end

  test "identical image payloads preserve distinct per-use accessibility metadata in export" do
    first=upload_media(alt_text: "First description")
    second=upload_media(alt_text: "Second description")
    assert_equal first.sha256, second.sha256
    item=draft(blocks: [ { "type"=>"image", "media_id"=>first.id }, { "type"=>"image", "media_id"=>second.id } ])
    change(item, "publish")
    payload=Portability::Export.call(actor: @owner)
    record=payload["content"].first
    assert_equal 1, payload["media"].length
    assert_equal 2, record["media_details"].length
    refute_equal record["blocks"][0]["media_detail_ref"], record["blocks"][1]["media_detail_ref"]
    assert Portability::Validate.call(JSON.generate(payload))
  end
end
