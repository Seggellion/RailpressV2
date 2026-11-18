require "test_helper"
require "vips"
require_relative "../support/portability_test_support"
class PortabilityIntegrityTest < ActiveSupport::TestCase
  include IdentityTestSupport
  include PortabilityTestSupport
  setup { install_site! }
  test "ordinary optional media NULL text exports through strict v2 without changing source metadata" do
    raw = Vips::Image.black(32, 24).new_from_image([ 72, 112, 145 ]).write_to_buffer(".png")
    assets = [ false, true ].map do |decorative|
      asset = MediaLibrary::Upload.call(actor: @owner, io: StringIO.new(raw), filename: "optional.png", content_type: "image/png",
        attributes: { "title" => "Synthetic optional metadata", "decorative" => decorative, "alt_text" => decorative ? "" : "A synthetic blue image" })
      page = Editorial::Workflow.create!(actor: @owner, kind: "Page", attributes: { "title" => "Media #{asset.id}", "featured_media_id" => asset.id.to_s })
      Editorial::Workflow.update!(actor: @owner, content: page, expected_version: page.lock_version, event: "publish")
      asset
    end
    original = assets.to_h { |asset| [ asset.id, asset.attributes.slice(*MediaAsset::METADATA) ] }
    rights = assets.to_h { |asset| [ asset.id.to_s, { "status" => "cleared", "license" => "Original synthetic qualification pixels", "attribution" => "Synthetic test fixture" } ] }
    session_id = portability_session
    %w[public owner_private].each do |mode|
      scope = { "mode" => mode, "content_ids" => mode == "public" ? [] : Content.pluck(:id), "history" => mode != "public", "author_labels" => {}, "media_rights" => rights, "menus" => false, "appearance" => false }
      record = Portability::Exports.request!(actor: @owner, session_id: session_id, scope: scope)
      Portability::Exports.perform!(record)
      assert_equal "ready", record.reload.state
      manifest, payloads = Railpress::SiteArchive.read(Portability::Store.read(record))
      assert_equal manifest, Portability::Format.check!(manifest, payloads)
      assert_equal 2, manifest["media"].length
      manifest["media"].each do |media|
        assert_equal "Synthetic optional metadata", media["metadata"]["title"]
        assert_equal [ "", "", "" ], media["metadata"].values_at("caption", "attribution", "license_notes")
        assert_equal media["metadata"]["decorative"] ? "" : "A synthetic blue image", media["metadata"]["alt_text"]
      end
      assert record.report["omissions"].any? { |row| row["absent_text_as_empty"]&.include?("caption") }
      malformed = manifest.deep_dup
      malformed["media"].first["metadata"]["caption"] = { "unexpected" => "object" }
      assert_raises(Portability::Format::Invalid) { Portability::Format.check!(malformed, payloads) }
    end
    assert_equal original, assets.to_h { |asset| [ asset.id, asset.reload.attributes.slice(*MediaAsset::METADATA) ] }
  end
  def media_manifest
    raw = Vips::Image.black(80, 40).new_from_image([ 36, 91, 120 ]).write_to_buffer(".png")
    source = MediaLibrary::Upload.call(actor: @owner, io: StringIO.new(raw), filename: "synthetic.png", content_type: "image/png", attributes: { "title"=>"Original synthetic image", "alt_text"=>"Blue rectangle", "caption"=>"Global caption", "license_notes"=>"Original synthetic work", "attribution"=>"Synthetic fixture" })
    manifest = portable_manifest; ref = SecureRandom.uuid
    media = { "ref"=>ref, "metadata"=>source.attributes.slice(*MediaAsset::METADATA), "rights"=>{ "status"=>"cleared", "license"=>"Original synthetic fixture", "attribution"=>"Synthetic fixture" }, "width"=>80, "height"=>40,
      "display"=>{ "sha256"=>source.sha256, "bytes"=>source.blob.byte_size }, "thumbnail"=>{ "sha256"=>source.thumbnail_sha256, "bytes"=>source.thumbnail_blob.byte_size } }
    manifest["media"] << media
    snapshot = manifest["content"][0]["working"]
    snapshot["featured_media_ref"] = ref
    snapshot["blocks"] << { "type"=>"image", "media_ref"=>ref, "caption"=>"Per-use caption" }
    snapshot["media_details"][ref] = source.accessibility_snapshot.merge("public_id"=>ref, "caption"=>"Historic per-use caption", "alt_text"=>"Historic alternative")
    manifest["content"][0]["live"] = snapshot.deep_dup
    payloads = { "media/#{source.sha256}.png"=>source.blob.download, "media/#{source.thumbnail_sha256}.png"=>source.thumbnail_blob.download }
    [ manifest, payloads, source ]
  end
  test "real media decoder preserves both canonical variant hashes captured descriptions and safe cleanup" do
    manifest, payloads, original = media_manifest
    batch, session_id = stage_portable(manifest, payloads: payloads)
    item = batch.import_items.find_by!(kind: "media")
    imported = MediaAsset.find(item.target_id)
    assert_equal original.sha256, imported.sha256
    assert_equal original.thumbnail_sha256, imported.thumbnail_sha256
    refute_equal original.id, imported.id
    content = Content.find(batch.import_items.find_by!(kind: "content").target_id)
    assert_equal imported.id, content.featured_media_id
    assert_equal "Historic per-use caption", content.media_details[imported.id.to_s]["caption"]
    assert_equal "Per-use caption", content.blocks.last["caption"]
    keys = [ imported.blob.key, imported.thumbnail_blob.key ]
    Portability::Reversal.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.lock_version)
    Portability::Worker.perform!(batch)
    assert MediaAsset.exists?(original.id)
    assert original.blob.service.exist?(original.blob.key)
    keys.each { |key| refute ActiveStorage::Blob.service.exist?(key) }
    refute MediaAsset.exists?(imported.id)
  end
  def replace_portable_png(manifest, payloads)
    source = manifest["media"].first
    %w[display thumbnail].each do |variant|
      record = source[variant]
      original = payloads.fetch("media/#{record['sha256']}.png")
      bytes = yield original
      source[variant] = { "sha256" => Digest::SHA256.hexdigest(bytes), "bytes" => bytes.bytesize }
      payloads["media/#{source[variant]['sha256']}.png"] = bytes
    end
    keep = %w[display thumbnail].map { |variant| "media/#{source[variant]['sha256']}.png" }
    payloads.select! { |name, _| keep.include?(name) }
  end
  def png_chunk(type, bytes)
    [ bytes.bytesize ].pack("N") + type + bytes + [ Zlib.crc32(type + bytes) ].pack("N")
  end
  test "portable canonical PNG compression differences preserve exact archived variants after bounded decoding" do
    manifest, payloads, = media_manifest
    original = manifest["media"].first["display"]["sha256"]
    replace_portable_png(manifest, payloads) do |bytes|
      offset = 8; prefix = bytes.byteslice(0, 8); compressed = "".b; suffix = "".b
      while offset < bytes.bytesize
        length = bytes.byteslice(offset, 4).unpack1("N"); type = bytes.byteslice(offset + 4, 4)
        if type == "IDAT"
          compressed << bytes.byteslice(offset + 8, length)
        elsif type == "IEND"
          suffix << bytes.byteslice(offset, length + 12)
        else
          prefix << bytes.byteslice(offset, length + 12)
        end
        offset += length + 12
      end
      prefix + png_chunk("IDAT", Zlib::Deflate.deflate(Zlib::Inflate.inflate(compressed), 9)) + suffix
    end
    refute_equal original, manifest["media"].first["display"]["sha256"]
    batch, = stage_portable(manifest, payloads: payloads)
    imported = MediaAsset.find(batch.import_items.find_by!(kind: "media").target_id)
    assert_equal manifest["media"].first["display"]["sha256"], imported.sha256
    assert_equal manifest["media"].first["thumbnail"]["sha256"], imported.thumbnail_sha256
    assert_equal payloads.fetch("media/#{imported.sha256}.png"), imported.blob.download
    assert_equal payloads.fetch("media/#{imported.thumbnail_sha256}.png"), imported.thumbnail_blob.download
  end
  test "portable PNG metadata and unbound variant preservation are refused without stored objects" do
    assert_raises(MediaLibrary::Upload::Rejected) do
      MediaLibrary::Upload.call(actor: @owner, io: StringIO.new(""), filename: "unbound.png", content_type: "image/png", import_thumbnail: "unbound")
    end
    manifest, payloads, = media_manifest
    original_assets = MediaAsset.count
    replace_portable_png(manifest, payloads) { |bytes| bytes.byteslice(0, 33) + png_chunk("tEXt", "Comment\x00Not portable metadata") + bytes.byteslice(33..) }
    session_id = portability_session
    batch = submit_portable(manifest, payloads: payloads, session_id: session_id)
    Portability::Imports.inspect!(batch)
    Portability::Imports.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.lock_version, decisions: portable_decisions(manifest))
    error = assert_raises(MediaLibrary::Upload::Rejected) { Portability::Worker.perform!(batch) }
    assert_match "import_png_metadata", error.message
    assert_equal original_assets, MediaAsset.count
    refute batch.reload.state == "complete"
    assert batch.import_items.where(kind: "media").all? { |item| item.target_id.nil? }
  end
  test "portable thumbnail receives its own bounded decoder validation before any blob is stored" do
    manifest, payloads, original = media_manifest
    original_assets = MediaAsset.count
    source = manifest["media"].first
    display = payloads.fetch("media/#{source['display']['sha256']}.png")
    malformed = display.byteslice(0, 33) + png_chunk("IDAT", Zlib::Deflate.deflate("\x00")) + png_chunk("IEND", "")
    sha = Digest::SHA256.hexdigest(malformed)
    source["thumbnail"] = { "sha256" => sha, "bytes" => malformed.bytesize }
    payloads["media/#{sha}.png"] = malformed
    session_id = portability_session
    batch = submit_portable(manifest, payloads: payloads, session_id: session_id)
    Portability::Imports.inspect!(batch)
    Portability::Imports.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.lock_version, decisions: portable_decisions(manifest))
    error = assert_raises(MediaLibrary::Upload::Rejected) { Portability::Worker.perform!(batch) }
    assert_match "decode", error.message
    assert_equal original_assets, MediaAsset.count
    assert original.blob.service.exist?(original.blob.key)
    assert MediaUpload.where(state: "rejected").all? { |upload| upload.storage_keys.empty? }
    assert batch.import_items.where(kind: "media").all? { |item| item.target_id.nil? }
  end
  test "partial worker interruption retries committed records without duplication and journal corruption refuses writes" do
    manifest = portable_manifest
    manifest["terms"] << { "ref"=>SecureRandom.uuid, "kind"=>"category", "name"=>"Considered spaces", "slug"=>"considered-spaces" }
    manifest["content"][0]["working"]["term_refs"] = [ manifest["terms"][0]["ref"] ]
    session_id = portability_session
    batch = submit_portable(manifest, session_id: session_id)
    Portability::Imports.inspect!(batch)
    Portability::Imports.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.lock_version, decisions: portable_decisions(manifest))
    assert_raises(IOError) { Portability::Worker.perform!(batch, fault: ->(event, _) { raise IOError, "synthetic worker interruption" if event == "after_term" }) }
    assert_equal 1, Term.count
    assert_empty Content.all
    assert_equal "blocked", batch.reload.state
    Portability::Imports.renew_approval!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.lock_version)
    Portability::Worker.perform!(batch)
    assert_equal "staged", batch.reload.state
    assert_equal 1, Term.count
    assert_equal 1, Content.count
    assert_equal [ Term.first.id ], Content.first.draft_terms.pluck(:id)
    assert Portability::Worker.verify!(batch)
    batch.import_items.first.update!(source_sha256: "0" * 64)
    assert_raises(Portability::Format::Invalid) { Portability::Worker.verify!(batch) }
  end
  test "nested menu references stage privately and source histories remain restorable" do
    manifest = portable_manifest; content_ref = manifest["content"][0]["ref"]
    root = SecureRandom.uuid; child = SecureRandom.uuid
    tree = [ { "ref"=>root, "parent_ref"=>nil, "position"=>0, "label"=>"Read our page", "kind"=>"Page", "target_ref"=>content_ref, "url"=>nil }, { "ref"=>child, "parent_ref"=>root, "position"=>0, "label"=>"Documentation", "kind"=>"Custom", "target_ref"=>nil, "url"=>"/docs" } ]
    manifest["menus"] << { "ref"=>SecureRandom.uuid, "name"=>"Portable hierarchy", "draft"=>tree, "live"=>tree.deep_dup, "locations"=>[] }
    snapshot = manifest["content"][0]["working"].deep_dup.merge("body"=>"<p>Exact historical body</p>")
    manifest["revisions"] << { "ref"=>SecureRandom.uuid, "content_ref"=>content_ref, "number"=>9, "event"=>"save", "created_at"=>"2021-04-05T10:11:12.123456789Z", "snapshot"=>snapshot, "history"=>manifest["content"][0]["history"].deep_dup }
    batch, = stage_portable(manifest)
    menu = Menu.find(batch.import_items.find_by!(kind: "menu").target_id)
    assert_nil menu.published_revision_id
    assert_equal 2, menu.tree.length
    rows = Navigation::Tree.ordered(menu.tree)
    assert_equal "Read our page", rows.first["label"]
    assert_equal rows.first["key"], rows.last["parent_key"]
    content = Content.first
    revision = ContentRevision.find(batch.import_items.find_by!(kind: "revision").target_id)
    assert_equal "2021-04-05T10:11:12.123456789Z", batch.import_items.find_by!(kind: "revision").details["source_record"]["created_at"]
    Editorial::Workflow.update!(actor: @owner, content: content, expected_version: content.lock_version, event: "restore_revision", revision_id: revision.id)
    assert_equal snapshot["body"], content.reload.body
    assert_equal "draft", content.status
    assert_nil content.published_at
  end
  test "two concurrent approvals of one optimistic batch yield one approval and one conflict" do
    manifest = portable_manifest; session_id = portability_session
    batch = submit_portable(manifest, session_id: session_id); Portability::Imports.inspect!(batch)
    version = batch.lock_version
    results = parallel_results(2) do
      Portability::Imports.approve!(batch: ImportBatch.find(batch.id), actor: User.find(@owner.id), session_id: session_id, expected_version: version, decisions: portable_decisions(manifest)); :approved
    rescue Editorial::Workflow::Conflict
      :conflict
    end
    assert_equal [ :approved, :conflict ], results.sort
    assert_equal 1, batch.import_items.count
  end
  test "corrupted created versus matched provenance cannot delete a preexisting taxonomy term" do
    manifest = portable_manifest
    existing = Editorial::Terms.create!(actor: @owner, kind: "category", name: "Preexisting exact term", slug: "preexisting-exact-term")
    ref = SecureRandom.uuid
    manifest["terms"] << { "ref"=>ref, "kind"=>"category", "name"=>existing.name, "slug"=>existing.slug }
    manifest["content"][0]["working"]["term_refs"] = [ ref ]
    session_id = portability_session
    batch = submit_portable(manifest, session_id: session_id)
    Portability::Imports.inspect!(batch)
    choices = portable_decisions(manifest)
    choices["terms"][ref] = { "action"=>"match", "target_id"=>existing.id }
    Portability::Imports.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.lock_version, decisions: choices)
    Portability::Worker.perform!(batch)
    item = batch.import_items.find_by!(kind: "term")
    refute item.created_record
    item.update!(created_record: true)
    assert Portability::Reversal.reasons(batch).any? { |reason| reason.include?("provenance") }
    assert_raises(Portability::Imports::Conflict) { Portability::Reversal.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.reload.lock_version) }
    assert Term.exists?(existing.id)
  end
end
