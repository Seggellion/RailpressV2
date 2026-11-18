module PortabilityTestSupport
  def portable_snapshot(kind: "Page", slug: "portable-page", title: "Portable Ω café")
    { "type"=>kind, "title"=>title, "slug"=>slug, "body"=>"<p>Unicode café 東京. <a href=\"/docs\">Documentation</a>.</p>", "excerpt"=>"A portable example", "visibility"=>"public", "template_key"=>"standard", "meta_title"=>"Portable title", "meta_description"=>"Portable description", "home_page"=>false,
      "author_ref"=>nil, "term_refs"=>[], "featured_media_ref"=>nil, "blocks"=>[ { "type"=>"heading", "text"=>"Considered content", "level"=>2 } ], "media_details"=>{}, "portable_metadata"=>{} }
  end
  def portable_manifest
    snapshot = portable_snapshot
    history = { "state"=>"published", "created_at"=>"2021-04-05T10:11:12.123456Z", "updated_at"=>"2023-04-05T10:11:12.123456Z", "published_at"=>"2022-04-05T10:11:12.123456Z", "first_published_at"=>"2022-04-05T10:11:12.123456Z", "scheduled_at"=>nil }
    { "format"=>"railpress.site", "version"=>2, "source"=>SecureRandom.uuid, "selection"=>"owner_private", "site"=>site_attributes.stringify_keys.merge("homepage_ref"=>nil, "organization_name"=>""),
      "authors"=>[], "content"=>[ { "ref"=>SecureRandom.uuid, "working"=>snapshot, "live"=>snapshot.deep_dup, "history"=>history } ], "revisions"=>[], "terms"=>[], "media"=>[], "menus"=>[], "redirects"=>[], "appearance"=>nil }
  end
  def portability_session(user = @owner)
    token = UserSession.issue!(user)
    UserSession.resolve(token).id
  end
  def portable_decisions(manifest)
    { "authors"=>{}, "unassigned"=>manifest["content"].to_h { |r| [ r["ref"], @owner.id ] }, "content"=>manifest["content"].to_h { |r| [ r["ref"], { "action"=>"create" } ] },
      "terms"=>manifest["terms"].to_h { |r| [ r["ref"], { "action"=>"create" } ] }, "media"=>manifest["media"].to_h { |r| [ r["ref"], { "action"=>"create", "rights_confirmed"=>true } ] }, "locations"=>"preserve_target", "settings"=>"preserve_target", "appearance"=>"preserve_target" }
  end
  def submit_portable(manifest, session_id:, payloads: {})
    bytes = Railpress::SiteArchive.build(manifest, payloads)
    Portability::Imports.submit!(actor: @owner, session_id: session_id, io: StringIO.new(bytes), idempotency_key: SecureRandom.hex(32))
  end
  def stage_portable(manifest, payloads: {})
    session_id = portability_session
    batch = submit_portable(manifest, session_id: session_id, payloads: payloads)
    Portability::Worker.perform!(batch)
    Portability::Imports.approve!(batch: batch, actor: @owner, session_id: session_id, expected_version: batch.reload.lock_version, decisions: portable_decisions(manifest))
    Portability::Worker.perform!(batch)
    [ batch.reload, session_id ]
  end
end
