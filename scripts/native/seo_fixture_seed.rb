# Synthetic test-only seed, always invoked through the verified native runner.
require "json"
raise "Fixture requires empty verified test records" unless Rails.env.test? && Site.count.zero? && User.count.zero? && Content.count.zero? && Seo::DiagnosticRun.count.zero? && SolidQueue::Job.count.zero?
state=Railpress::BootstrapState.for_application
claim=state.claim!(state.issue!)
Setup::Complete.call(state: state, claim: claim,
  site_attributes: { title: "Railpress SEO fixture", tagline: "Original synthetic correctness fixture", canonical_origin: "https://localhost:58105", locale: "en", timezone: "America/Vancouver", home_mode: "static", indexing_enabled: true },
  owner_attributes: { username: "seo-fixture-owner", email: "seo-fixture-owner@example.invalid", password: "synthetic-seo-owner-2026!", password_confirmation: "synthetic-seo-owner-2026!" })
owner=User.first
site=Site.first
site.update!(organization_name: "Original synthetic studio")
category=Editorial::Terms.create!(actor: owner, kind: "category", name: "Announcements", slug: "announcements")
make=->(kind, slug, extra = {}) do
  item=Editorial::Workflow.create!(actor: owner, kind: kind, attributes: { "title"=>"Fixture #{slug}", "slug"=>slug, "body"=>"<p>Original public fixture — 日本語.</p>", "excerpt"=>"Local SEO proof" }.merge(extra))
  Editorial::Workflow.update!(actor: owner, content: item, expected_version: item.lock_version, event: "publish")
end
make.call("Page", "home", { "home_page"=>true })
make.call("Page", "about")
post=make.call("Post", "news", { "term_ids"=>[ category.id ] })
make.call("Post", "private", { "visibility"=>"private" })
draft=Editorial::Workflow.create!(actor: owner, kind: "Post", attributes: { "title"=>"PRIVATE DRAFT CANARY", "slug"=>"secret", "body"=>"<p>PRIVATE DRAFT BODY</p>" })
scheduled=Editorial::Workflow.create!(actor: owner, kind: "Post", attributes: { "title"=>"FUTURE CANARY", "slug"=>"future", "body"=>"<p>FUTURE BODY</p>" })
Editorial::Workflow.update!(actor: owner, content: scheduled, expected_version: scheduled.lock_version, event: "schedule",
  attributes: { "schedule_local"=>2.hours.from_now.in_time_zone(site.timezone).strftime("%Y-%m-%dT%H:%M") })
File.write(ENV.fetch("RAILPRESS_SEO_FIXTURE_INFO"), JSON.generate(install_id: site.install_id, post_id: post.id, content_count: Content.count))
puts "Verified synthetic M05 rendering fixture seeded"
