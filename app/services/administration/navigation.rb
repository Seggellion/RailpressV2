module Administration
  module Navigation
    Entry = Data.define(:key, :label, :route, :params, :capability)
    def self.entry(key, label, route, capability, **params)
      Entry.new(key: key, label: label, route: route, params: params.freeze, capability: capability)
    end
    GROUPS = [
      [ "dashboard", "Dashboard", [ entry("dashboard", "Dashboard", :admin_path, :admin) ] ],
      [ "content", "Content", [
        entry("pages", "Pages", :admin_contents_path, :edit_own, kind: "Page"),
        entry("posts", "Posts", :admin_contents_path, :edit_own, kind: "Post"),
        entry("categories", "Categories", :admin_terms_path, :publish_others, kind: "category"),
        entry("tags", "Tags", :admin_terms_path, :publish_others, kind: "tag")
      ] ],
      [ "media", "Media", [ entry("media", "Media library", :admin_media_assets_path, :admin) ] ],
      [ "appearance", "Appearance", [
        entry("themes", "Themes", :admin_themes_path, :manage_themes),
        entry("customize", "Customize", :admin_customize_path, :manage_themes),
        entry("menus", "Menus", :admin_menus_path, :manage_menus)
      ] ],
      [ "seo", "SEO", [ entry("seo", "SEO correctness", :admin_seo_path, :execute_seo) ] ],
      [ "users", "Users", [ entry("users", "Users and roles", :admin_users_path, :manage_users) ] ],
      [ "settings", "Settings", [ entry("settings", "Site settings", :admin_settings_path, :manage_identity), entry("accounts", "Accounts", :admin_accounts_path, :manage_identity), entry("privacy", "Privacy", :admin_privacy_path, :manage_identity) ] ],
      [ "tools", "Tools", [
        entry("updates", "Updates", :admin_updates_path, :inspect_updates),
        entry("official_news", "Official news", :admin_official_news_path, :manage_identity),
        entry("portability", "Import / Export", :admin_imports_path, :manage_identity),
        entry("readiness", "Site Readiness", :admin_readiness_path, :view_readiness),
        entry("activity", "Activity", :admin_activity_path, :view_activity)
      ] ]
    ].map { |key, label, children| [ key, label, children.freeze ].freeze }.freeze
    def self.for(user)
      GROUPS.filter_map do |key, label, children|
        visible = children.select { |entry| Identity::Capabilities.allowed?(user, entry.capability) }
        [ key, label, visible ] if visible.any?
      end
    end
    def self.validate!
      GROUPS.flat_map(&:last).each do |entry|
        path = Rails.application.routes.url_helpers.public_send(entry.route, **entry.params)
        raise "Invalid protected navigation route" unless path.start_with?("/admin") && !path.start_with?("//")
      end
    end
  end
end
