# frozen_string_literal: true

module Identity
  module Capabilities
    class Denied < StandardError; end
    RIGHTS = {
      "owner" => %i[admin edit_own edit_others publish_others manage_media manage_menus manage_users manage_identity manage_themes manage_modules review_extension_records inspect_updates execute_seo view_activity view_readiness],
      "administrator" => %i[admin edit_own edit_others publish_others manage_media manage_menus review_extension_records view_activity view_readiness],
      "editor" => %i[admin edit_own edit_others publish_others manage_media view_activity],
      "author" => %i[admin edit_own upload_own view_activity]
    }.freeze
    module_function
    def allowed?(user, capability)
      user.is_a?(User) && RIGHTS.fetch(user.role, []).include?(capability)
    end
    def require!(user, capability)
      raise Denied, "This action is not permitted" unless allowed?(user, capability)
    end
    def can_edit_content?(user, author_id:)
      allowed?(user, :edit_others) || (allowed?(user, :edit_own) && user.id == author_id)
    end
  end
end
