# Execute only through bin/native_test on an already empty verified schema.
require "json"
require "bcrypt"
raise "Empty synthetic test schema required" unless Rails.env.test? && ActiveRecord::Base.connection.tables.empty?
pool=ActiveRecord::Base.connection_pool
pool.migration_context.migrate(20261111080100)
model=->(table) { Class.new(ActiveRecord::Base) { self.table_name=table;self.inheritance_column=:_unused_type } }
users=model.call("users");sites=model.call("sites");contents=model.call("contents")
now=Time.current
owner=users.create!(username: "upgrade-owner", email: "upgrade-owner@example.invalid", username_key: Digest::SHA256.hexdigest("upgrade-owner"),
  email_key: Digest::SHA256.hexdigest("upgrade-owner@example.invalid"), password_digest: BCrypt::Password.create("synthetic-upgrade-only", cost: 4), role: "owner", created_at: now, updated_at: now)
site=sites.create!(singleton_key: 1, install_id: SecureRandom.uuid, owner_id: owner.id, title: "Synthetic upgrade", tagline: "Original fixture", canonical_origin: "https://upgrade.example.invalid", locale: "en", timezone: "Etc/UTC", indexing_enabled: true, home_mode: "static", created_at: now, updated_at: now)
items=%w[Page Post].map do |type|
  slug=type=="Page" ? "home" : "news"
  snapshot={ "type"=>type, "title"=>"Approved 日本語 #{type}", "slug"=>slug, "body"=>"<p>APPROVED UTF-8 — 日本語.</p>", "excerpt"=>"Approved excerpt", "author_id"=>owner.id, "visibility"=>"public", "template_key"=>"standard", "home_page"=>type=="Page", "blocks"=>[], "media_details"=>{}, "term_ids"=>[] }
  contents.create!(type: type, title: "PRIVATE WORKING TITLE", slug: slug, slug_key: Digest::SHA256.hexdigest(slug), body: "PRIVATE WORKING BODY", excerpt: "PRIVATE WORKING SUMMARY",
    author_id: owner.id, status: "published", visibility: "public", published_visibility: "public", template_key: "standard", published_snapshot: snapshot, published_at: now, first_published_at: now,
    home_page: type=="Page", created_at: now, updated_at: now)
end
site.update_columns(homepage_content_id: items.first.id)
before=items.map { |item|item.published_snapshot }
pool.migration_context.migrate(20261111100000)
contents.reset_column_information
after=items.map { |item|contents.find(item.id) }
raise "Snapshot changed during upgrade" unless after.map(&:published_snapshot)==before
raise "Private search leaked" unless after.all? { |item|item.public_search_text.include?("Approved") && !item.public_search_text.include?("PRIVATE") }
raise "Public path backfill failed" unless after.map(&:last_public_path)==[ "/", "/blog/news" ]
raise "Meaningful time lost" unless after.all? { |item|item.public_updated_at.to_i==now.to_i }
report={ engine: ENV.fetch("RAILPRESS_TEST_ENGINE"), from_migration: 20261111080100, to_migration: 20261111100000, records: 2,
  snapshots_unchanged: true, private_working_search_excluded: true, public_paths: after.map(&:last_public_path), public_time_preserved: true,
  snapshot_sha256: before.map { |snapshot|Digest::SHA256.hexdigest(Portability::CanonicalJson.dump(snapshot)) } }
File.write(Rails.root.join("docs/evidence/#{ENV.fetch('RAILPRESS_EVIDENCE_MILESTONE', 'M06')}/#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-upgrade.json"), JSON.pretty_generate(report)+"\n")
puts "M04_TO_M05_UPGRADE: #{JSON.generate(report)}"
