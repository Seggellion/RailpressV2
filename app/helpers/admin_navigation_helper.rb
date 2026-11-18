module AdminNavigationHelper
  def admin_navigation_path(entry)
    public_send(entry.route, **entry.params)
  end
  def admin_active_key
    case controller_path
    when "admin/dashboard" then "dashboard"
    when "admin/contents"
      kind = @content&.type || params[:kind]
      { "Page" => "pages", "Post" => "posts" }[kind]
    when "admin/terms" then params[:kind] == "tag" ? "tags" : "categories"
    when "admin/media_assets" then "media"
    when "admin/themes" then action_name == "customize" ? "customize" : "themes"
    when "admin/menus" then "menus"
    when "admin/seo" then "seo"
    when "admin/users" then "users"
    when "admin/settings" then "settings"
    when "admin/accounts" then "accounts"
    when "admin/privacy" then "privacy"
    when "admin/protected_features", "admin/updates" then "updates"
    when "admin/tools", "admin/exports", "admin/imports", "admin/site_exports" then "portability"
    when "admin/readiness" then "readiness"
    when "admin/official_news" then "official_news"
    when "admin/activity" then "activity"
    end
  end
  def admin_group_active?(key, entries)
    entries.any? { |entry| entry.key == admin_active_key } ||
      (key == "content" && %w[admin/contents admin/terms].include?(controller_path))
  end
  def admin_session_binding
    record = Current.user_session
    Digest::SHA256.hexdigest([ record&.token_digest, current_user&.id, current_user&.auth_version ].join(":"))
  end
end
