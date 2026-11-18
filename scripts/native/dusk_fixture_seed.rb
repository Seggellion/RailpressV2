# Dedicated synthetic-only Dusk qualification. Never a production seed.
require "vips"
require "stringio"
require Rails.root.join("lib/railpress/dusk_package")
require Rails.root.join("lib/railpress/theme_fixture")
raise "verified empty fixture required" unless Rails.env.test? && ENV["RAILPRESS_TEST_CONFIRM"] == "railpress-synthetic-only" && Site.count.zero? && User.count.zero? && Content.count.zero? && MediaAsset.count.zero?
target = Railpress::TestDatabase.load!(root: Rails.root, engine: ENV.fetch("RAILPRESS_TEST_ENGINE"))
Railpress::TestDatabase.verify!(target)
ActiveModel::SecurePassword.min_cost = true
state = Railpress::BootstrapState.for_application
claim = state.claim!(state.issue!)
password = SecureRandom.hex(24)
Setup::Complete.call(state: state, claim: claim,
  site_attributes: { title: "Aster Studio", tagline: "Considered spaces. Everyday life.", canonical_origin: "https://localhost:59107", locale: "en", timezone: "UTC", home_mode: "static", indexing_enabled: true },
  owner_attributes: { username: "dusk-fixture-owner", email: "dusk-fixture@example.invalid", password: password, password_confirmation: password })
owner = User.first
fixture_install_id = Site.first.install_id
# Retain a guarded partial identity if fixture construction fails.
at_exit do
  if $! && Site.count == 1 && Site.first.install_id == fixture_install_id
    File.write(ENV.fetch("RAILPRESS_DUSK_FIXTURE_INFO"), JSON.generate(install_id: fixture_install_id, content_count: Content.count, partial_seed: true), perm: 0o600)
  end
end
art = Vips::Image.black(1200, 720).new_from_image([ 224, 211, 193 ]).copy_memory
art = art.draw_rect([ 69, 91, 85 ], 100, 90, 330, 540, fill: true)
art = art.draw_rect([ 167, 77, 49 ], 470, 240, 280, 390, fill: true)
art = art.draw_rect([ 244, 239, 228 ], 790, 90, 310, 540, fill: true)
asset = MediaLibrary::Upload.call(actor: owner, io: StringIO.new(art.write_to_buffer(".png")), filename: "aster-study.png", content_type: "image/png",
  attributes: { title: "A study in balance", alt_text: "Original geometric study: forest, terracotta and cream panels on warm paper.", caption: "A study in balance — original synthetic artwork.", license_notes: "Original Railpress qualification artwork, MIT." }.stringify_keys)
category = Editorial::Terms.create!(actor: owner, kind: "category", name: "Field notes", slug: "field-notes")
tag = Editorial::Terms.create!(actor: owner, kind: "tag", name: "Materials", slug: "materials")
make = lambda do |kind, slug, title, attributes = {}|
  record = Editorial::Workflow.create!(actor: owner, kind: kind, attributes: { title: title, slug: slug, body: "<p>Good spaces begin with listening. We bring a careful eye, clear thinking and a practical approach to the details of everyday life.</p>", excerpt: "Thoughtful ideas, useful details and a little room to breathe." }.merge(attributes).stringify_keys)
  Editorial::Workflow.update!(actor: owner, content: record, expected_version: record.lock_version, event: "publish")
end
blocks = [
  { type: "hero", heading: "A little perspective. A lasting difference.", text: "From the first conversation to the finishing details, thoughtful choices make a place feel like yours.", label: "How we can help", url: "/services" },
  { type: "heading", text: "Good spaces start with good questions.", level: 2 },
  { type: "features", items: [ { heading: "A clear starting point", text: "A focused consultation to understand your space, your priorities and the possibilities ahead." }, { heading: "A considered plan", text: "Materials, colour and layout brought together with purpose, clarity and care." }, { heading: "The finishing details", text: "Practical guidance to bring the individual pieces into a coherent whole." } ] },
  { type: "image", media_id: asset.id, caption: "A study in balance — an original composition." },
  { type: "heading", text: "People first. Details always.", level: 2 },
  { type: "paragraph", html: "<p>We are a small, independent design studio. Our work is grounded in conversation: what matters to you, how you live and what could work a little better.</p><p>This is a synthetic qualification site, with original demonstration copy and artwork.</p>" },
  { type: "testimonial", quote: "The process gave us clarity, confidence and a space that feels like us.", attribution: "Synthetic client quotation — qualification fixture only" },
  { type: "heading", text: "Before we begin", level: 2 },
  { type: "faq", items: [ { question: "Where do we start?", answer: "A conversation about your priorities is the first step. Our contact page explains how to get in touch." }, { question: "Can we begin with one room?", answer: "Yes. A focused project can be a useful place to explore a larger idea." } ] },
  { type: "call_to_action", heading: "Make room for your next chapter.", text: "A useful conversation is a good place to begin.", label: "Start a conversation", url: "/contact" }
].map(&:deep_stringify_keys)
home = make.call("Page", "home", "Thoughtful spaces.\nEveryday possibilities.", home_page: true, blocks: blocks, excerpt: "Independent design for the places we live, work and come together.")
make.call("Page", "services", "A clear path from idea to everyday.", blocks: ContentBlocks::Patterns.fetch("services") + ContentBlocks::Patterns.fetch("faq"))
make.call("Page", "about", "A small studio. A thoughtful approach.", blocks: ContentBlocks::Patterns.fetch("about"))
make.call("Page", "contact", "Let's begin with a conversation.", blocks: [ { "type" => "contact", "heading" => "Contact Aster Studio", "address" => "Synthetic demonstration studio — no visitor address", "email" => "hello@example.invalid", "phone" => "" } ])
make.call("Page", "privacy", "Privacy & your information", body: "<h2>Information you choose to share</h2><p>This synthetic site uses no analytics or external tracking assets. This fixture is not a production privacy policy.</p>")
make.call("Page", "docs", "A useful guide to working together", body: "<h2>Getting started</h2><p>Begin with your priorities, a few useful measurements and the questions you would like to explore.</p><h2>Our process</h2><p>Listen, consider, plan and refine. Each step has room for conversation.</p>")
make.call("Page", "long-read", "A longer perspective — 日本語, Café & everyday life", body: "<h2>A little room for detail</h2>" + ("<p>Material, light and texture shape how a place feels. 日本語の文章と Café — " + "long_unbroken_detail_" * 12 + "</p>") * 45)
make.call("Page", "missing-media", "When an image is unavailable", blocks: [ { "type" => "image", "media_id" => asset.id } ])
13.times do |index|
  title = [ "The quiet value of a considered corner", "Finding a rhythm in everyday spaces", "Materials that tell a longer story" ][index % 3]
  make.call("Post", "note-#{index + 1}", "#{title}#{index > 2 ? " — #{index + 1}" : ""}", term_ids: [ category.id, tag.id ], featured_media_id: index.zero? ? asset.id : nil)
end
private_record = make.call("Post", "private", "PRIVATE DUSK CANARY", visibility: "private")
Editorial::Workflow.create!(actor: owner, kind: "Post", attributes: { title: "DRAFT DUSK CANARY", slug: "draft", body: "<p>PRIVATE WORKING BODY</p>" }.stringify_keys)
scheduled = Editorial::Workflow.create!(actor: owner, kind: "Post", attributes: { title: "FUTURE DUSK CANARY", slug: "future", body: "<p>PRIVATE FUTURE BODY</p>" }.stringify_keys)
Editorial::Workflow.update!(actor: owner, content: scheduled, expected_version: scheduled.lock_version, event: "schedule", attributes: { "schedule_local" => 2.hours.from_now.utc.strftime("%Y-%m-%dT%H:%M") })
theme_root = Themes::Storage.root
signer = OpenSSL::PKey.generate_key("ED25519")
File.write(File.join(theme_root, "trusted-keys.json"), JSON.generate(Digest::SHA256.hexdigest(signer.public_to_der) => signer.public_to_pem), perm: 0o600)
directory = Railpress::DuskPackage.build(File.join(theme_root, "dusk-candidate"), root: Rails.root, signer: signer)
package = Themes::Manager.stage!(actor: owner, directory: directory)
overlay = package.theme_overlays.first
token = UserSession.issue!(owner)
Themes::Manager.preview!(actor: owner, installation: package, overlay: overlay, authentication_token: token)
Themes::Manager.activate!(actor: owner, installation: package, overlay: overlay, version: 0)
candidate = Themes::Manager.overlay!(actor: owner, installation: package, attributes: { palette: "woodland", font: "system_sans", layout: "reading", header_style: "centered", footer_style: "compact", brand_label: "Aster Atelier", footer: "PRIVATE DUSK OVERLAY CANARY" })
broken_directory = File.join(theme_root, "broken-candidate")
Railpress::ThemeFixture.build(broken_directory, root: Rails.root, signer: signer, id: "harbor", version: "7.0.0",
 mutate: ->(manifest, dir) { Railpress::ThemeFixture.replace(manifest, dir, "templates/navigation.html.erb", '<% raise "synthetic broken component" if theme.site.title == "Aster Studio" %><header>Safe smoke</header>') })
broken = Themes::Manager.stage!(actor: owner, directory: broken_directory)
ThemePreview.delete_all; UserSession.delete_all
File.write(ENV.fetch("RAILPRESS_DUSK_FIXTURE_INFO"), JSON.generate(install_id: Site.first.install_id, password: password, content_count: Content.count, home_id: home.id, asset_id: asset.id, package_id: package.id, overlay_id: overlay.id, candidate_id: candidate.id, broken_id: broken.id, digest: package.digest), perm: 0o600)
puts "Original generic Dusk fixture seeded; private credentials omitted"
