# Explicit qualification support. Never required by app boot, db/seeds or release tasks.
require "json"
require "digest"
require "stringio"
module GenericSiteFixture
  class Invalid < StandardError; end
  module_function
  def guard!
    raise Invalid, "Explicit synthetic fixture confirmation required" unless ENV["RAILPRESS_GENERIC_FIXTURE"] == "generic-synthetic-only"
    engine = ENV.fetch("RAILPRESS_TEST_ENGINE")
    if Rails.env.production?
      # Native qualification carries explicit DB fields. Do not clear or hide
      # them to pass the test runner's inherited-environment prohibition.
      profile = ENV["RAILPRESS_NATIVE_TEST_PROFILE"]
      raise Invalid, "Unknown synthetic profile" if profile && !Railpress::TestDatabase::PROFILES.key?(profile)
      registry = Rails.root.join(".local/state", Railpress::TestDatabase.registry_file(profile))
      stat = registry.lstat
      raise Invalid, "Private native registry required" unless stat.file? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
      raise Invalid, "Native DATABASE_URL prohibited" if ENV["DATABASE_URL"]
      targets = JSON.parse(registry.read)
      targets = targets.fetch(profile) if profile
      target = targets.fetch(engine)
      raise Invalid, "Profile identity mismatch" if profile && target["run_id"] != Railpress::TestDatabase::PROFILES.fetch(profile)
      Railpress::TestDatabase.validate!(target, environment: "test", confirmed: "railpress-synthetic-only")
      data = File.realpath(target.fetch("data_directory"))
      raise Invalid, "Dedicated native data root required" unless data.start_with?(Rails.root.join(".local/state").realpath.to_s + "/") && File.stat(data).uid == Process.uid
      mapping = { "ADAPTER"=>"adapter", "HOST"=>"host", "PORT"=>"port", "NAME"=>"database", "USER"=>"username", "PASSWORD"=>"password" }
      raise Invalid, "Exact native connection environment required" unless mapping.all? { |key, field| ENV["RAILPRESS_DB_#{key}"] == target[field].to_s }
    elsif Rails.env.test?
      target = Railpress::TestDatabase.load!(root: Rails.root, engine: engine, environment: "test", confirmed: "railpress-synthetic-only")
    else
      raise Invalid, "Only explicit synthetic qualification processes permitted"
    end
    current = ActiveRecord::Base.connection_db_config.configuration_hash
    raise Invalid, "Connection must match the exact dedicated target" unless %w[adapter host port database username password].all? { |key| current[key.to_sym].to_s == target[key].to_s }
    Railpress::TestDatabase.verify!(target, environment: "test", confirmed: "railpress-synthetic-only")
    target
  end
  def corpus
    JSON.parse(File.read(Rails.root.join("test/fixtures/generic_site/corpus.json")), max_nesting: 20)
  end
  def validate!(value = corpus)
    raise Invalid, "Editorial format" unless value["format"] == "railpress.synthetic-editorial.v1" && value["articles"].is_a?(Array) && value["articles"].length == 20
    root = Rails.root.join("test/fixtures/generic_site").realpath
    rows = value["articles"]
    raise Invalid, "Exact editorial slate required" unless rows.map { |row| row["number"] } == (1..20).to_a
    raise Invalid, "Duplicate identities" unless rows.map { |r| r["id"] }.uniq.length == 20 && rows.map { |r| r["slug"] }.uniq.length == 20
    rows.each do |row|
      raise Invalid, "Stable editorial identity required" unless row["id"].is_a?(String) && row["id"].match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
      raise Invalid, "Private review gate required" unless row.values_at("status", "visibility", "public_byline", "owner_review", "publication_date") == [ "draft", "private", "UNASSIGNED", "AWAITING OWNER REVIEW", nil ]
      raise Invalid, "Unsupported Post identity" unless row["slug"].present? && row["slug"] == Railpress::ContentRoutes.slug(row["slug"]) && row["canonical_path"] == "/blog/#{row['slug']}"
      file = row["body_file"]
      raise Invalid, "Unsafe editorial path" unless file.is_a?(String) && file.match?(/\Aarticles\/[0-9]{2}-[a-z0-9-]+\.html\z/)
      path = root.join(file)
      raise Invalid, "Owned editorial body required" unless path.file? && !path.symlink? && path.realpath.to_s.start_with?(root.to_s + "/") && path.size.between?(1, 200_000)
      body = File.read(path)
      raise Invalid, "Body hash mismatch" unless Digest::SHA256.hexdigest(body) == row["body_sha256"]
      fragment = Nokogiri::HTML5.fragment(body)
      raise Invalid, "Unsafe editorial markup" unless fragment.css("*").all? { |node| Editorial::RichText::TAGS.include?(node.name) && (node.attribute_nodes.map(&:name) - %w[href title scope]).empty? }
      fragment.css("a[href]").each { |node| ContentBlocks::Schema.url(node["href"]) }
      raise Invalid, "Incomplete editorial body" unless fragment.text.split.length >= 400 && fragment.css("h2").length >= 3
      ContentBlocks::Schema.normalize(row.fetch("blocks"))
    end
    rows
  rescue JSON::ParserError, KeyError, TypeError, NoMethodError, Errno::ENOENT, ContentBlocks::Schema::Invalid => error
    raise Invalid, "Invalid editorial fixture: #{error.class}"
  end
  def mutate(actor, menu, operation, payload)
    Installation::Starter.mutate(actor, menu, operation, payload)
  end
  def load!(actor:)
    guard!
    rows = validate!
    profile = JSON.parse(File.read(Rails.root.join("test/fixtures/generic_site/profile.json")))
    Site.transaction do
      site = Site.lock.find_by!(singleton_key: 1)
      fresh = User.lock.find(actor.id)
      Identity::Capabilities.require!(fresh, :manage_identity)
      Identity::Capabilities.require!(fresh, :publish_others)
      raise Invalid, "Fresh ordinary starter required; existing content is never overwritten" unless Page.count == 1 && Page.first.slug == "welcome" && Post.count == 1 && Post.first.slug == "your-first-story" && Post.first.status == "draft" && Term.count.zero?
      raise Invalid, "Synthetic origin must be configured during setup" unless site.canonical_origin == profile.dig("site", "canonical_origin")
      site.update!(profile.fetch("site").except("canonical_origin"))
      Activity::Recorder.record!(actor: fresh, action: "identity.site_updated", subject: site)
      pages = {}
      profile.fetch("pages").each do |entry|
        attributes = entry.slice(*Editorial::Workflow::FIELDS).merge("blocks" => entry.fetch("blocks"))
        item = entry["home_page"] ? Page.first : Editorial::Workflow.create!(actor: fresh, kind: "Page", attributes: attributes)
        Editorial::Workflow.update!(actor: fresh, content: item, expected_version: item.lock_version, attributes: attributes, event: "publish")
        pages[entry.fetch("slug")] = item
      end
      terms = {}
      rows.each do |row|
        [ [ "category", row.fetch("category") ], *row.fetch("tags").map { |name| [ "tag", name ] } ].each do |kind, name|
          terms[[ kind, name ]] ||= Editorial::Terms.create!(actor: fresh, kind: kind, name: name, slug: name)
        end
      end
      starter = Post.first
      posts = rows.each_with_index.to_h do |row, index|
        term_ids = [ terms.fetch([ "category", row["category"] ]).id, *row["tags"].map { |name| terms.fetch([ "tag", name ]).id } ]
        attributes = row.slice("title", "slug", "excerpt", "meta_title", "meta_description", "visibility", "blocks").merge("body" => File.read(Rails.root.join("test/fixtures/generic_site", row["body_file"])), "term_ids" => term_ids)
        item = index.zero? ? Editorial::Workflow.update!(actor: fresh, content: starter, expected_version: starter.lock_version, attributes: attributes) : Editorial::Workflow.create!(actor: fresh, kind: "Post", attributes: attributes)
        [ row.fetch("id"), item ]
      end
      # Replace only the known fresh starter menu through its audited service.
      Menu.where(site: site, status: "active").each { |menu| mutate(fresh, menu, "delete", {}) }
      menus = profile.fetch("menus").map do |definition|
        menu = mutate(fresh, nil, "create", { "name" => definition.fetch("name") })
        keys = {}
        definition.fetch("items").each do |item|
          target = item["page"] ? { "kind"=>"Page", "content_id"=>pages.fetch(item["page"]).id } : { "kind"=>"Custom", "url"=>item.fetch("url") }
          menu = mutate(fresh, menu, "add", { "item"=>target.merge("label"=>item.fetch("label")) })
          keys[item.fetch("key")] = menu.tree.last.fetch("key")
        end
        positions = Hash.new(0)
        tree = definition.fetch("items").map do |item|
          parent = item["parent"] && keys.fetch(item["parent"])
          position = positions[parent]; positions[parent] += 1
          { "key"=>keys.fetch(item.fetch("key")), "parent_key"=>parent, "position"=>position }
        end
        menu = mutate(fresh, menu, "reparent", { "tree"=>tree })
        menu = mutate(fresh, menu, "assign", { "locations"=>definition.fetch("locations") })
        mutate(fresh, menu, "publish", {})
      end
      package = ThemeState.find_by!(site: site).active_installation
      raise Invalid, "Ordinary Dusk required" unless package.theme_key == "dusk"
      branding = profile.fetch("branding").dup
      overlay = Themes::Manager.overlay!(actor: fresh, installation: package, attributes: branding)
      token = UserSession.issue!(fresh)
      begin
        Themes::Manager.preview!(actor: fresh, installation: package, overlay: overlay, authentication_token: token)
        Themes::Manager.activate!(actor: fresh, installation: package, overlay: overlay, version: ThemeState.find_by!(site: site).lock_version)
      ensure
        ThemePreview.where(session_digest: Digest::SHA256.hexdigest(token)).delete_all
        UserSession.where(token_digest: Digest::SHA256.hexdigest(token)).delete_all
      end
      { pages: pages, posts: posts, menus: menus, overlay: overlay }
    end
  end
  def synthetic_posts!(actor:, count: 13)
    guard!
    category = Editorial::Terms.create!(actor: actor, kind: "category", name: "Synthetic qualification examples", slug: "qualification-examples")
    tag = Editorial::Terms.create!(actor: actor, kind: "tag", name: "Synthetic layout test", slug: "synthetic-layout-test")
    count.times.map do |index|
      attributes = { "title"=>index.zero? ? "Synthetic story: a clear place to begin" : "Synthetic layout note #{index + 1}",
        "slug"=>index.zero? ? "synthetic-clear-reading" : "synthetic-layout-note-#{index + 1}", "excerpt"=>"Clearly labeled synthetic qualification content. This is not one of the twenty unapproved editorial drafts.",
        "body"=>synthetic_body, "visibility"=>"public", "term_ids"=>[ category.id, tag.id ] }
      item = Editorial::Workflow.create!(actor: actor, kind: "Post", attributes: attributes)
      Editorial::Workflow.update!(actor: actor, content: item, expected_version: item.lock_version, event: "publish")
    end
  end
  def synthetic_body
    '<p>This is a synthetic rendering and transport fixture, approved only for isolated qualification. It is not a real product announcement, named author or public release.</p><h2>A page with a clear reading path</h2><p>A visitor should be able to identify the subject, follow the sections and reach a useful next action. This fixture checks those relationships with ordinary CMS content and the same theme used by the site.</p><p>The opening paragraph gives context. The following headings separate the narrative into understandable parts. None of these paragraphs is copied from the private editorial corpus. Their purpose is to exercise the presentation contract without making an unreviewed draft public.</p><h3>Useful details stay readable</h3><p>Long text should wrap at narrow viewports. Unicode remains text: Café, 日本語, مرحبا and a considered em dash — all belong in a normal reading experience. A line with a long identifier follows:</p><pre><code>example_identifier_for_layout_only_abcdefghijklmnopqrstuvwxyz_abcdefghijklmnopqrstuvwxyz_abcdefghijklmnopqrstuvwxyz_abcdefghijklmnopqrstuvwxyz</code></pre><h2>Relationships in a small table</h2><table><caption>Synthetic layout checks</caption><thead><tr><th scope="col">Example</th><th scope="col">Intended behavior</th></tr></thead><tbody><tr><th scope="row">Private draft</th><td>Not an anonymous public article.</td></tr><tr><th scope="row">Published fixture</th><td>Approved synthetic content through ordinary core policy.</td></tr></tbody></table><blockquote>A fixture is evidence of a tested behavior, not evidence of a public launch.</blockquote><h2>A deliberate next step</h2><ol><li>Review the reading order.</li><li>Follow a meaningful local link.</li><li>Test keyboard focus, narrow layout and enlarged zoom.</li></ol><p>Visit <a href="/docs/getting-started">Getting Started</a> or <a href="/features">Feature Status</a>. Those are real ordinary Page destinations in the isolated official-site profile.</p>'
  end
end
