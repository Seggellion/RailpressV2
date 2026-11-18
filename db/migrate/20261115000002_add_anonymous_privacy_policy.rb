class AddAnonymousPrivacyPolicy < ActiveRecord::Migration[8.1]
  def change
    # Existing sites are never silently switched. New Site objects opt in.
    add_column :sites, :privacy_first_anonymous, :boolean, null: false, default: false
    add_column :sites, :privacy_revision, :integer, null: false, default: 0
    add_check_constraint :sites, "privacy_revision >= 0", name: "site_privacy_revision_nonnegative"
  end
end
