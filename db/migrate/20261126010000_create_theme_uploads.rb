# frozen_string_literal: true

class CreateThemeUploads < ActiveRecord::Migration[8.1]
  def change
    create_table :theme_uploads do |table|
      table.references :site, null: false, foreign_key: true
      table.references :theme_installation, foreign_key: true
      table.bigint :actor_id, null: false
      table.integer :actor_auth_version, null: false
      table.string :operation_key, limit: 36, null: false
      table.string :transport_sha256, limit: 64, null: false
      table.integer :byte_size, null: false
      table.string :state, limit: 20, null: false
      table.string :result_code, limit: 48
      table.string :manifest_sha256, limit: 64
      table.json :overlay_mapping
      table.timestamps
      table.index :operation_key, unique: true
    end

    add_column :theme_installations, :upload_publisher, :string, limit: 64
    add_column :theme_previews, :state_version, :integer
    add_column :theme_previews, :engine_fingerprint, :string, limit: 64
  end
end
