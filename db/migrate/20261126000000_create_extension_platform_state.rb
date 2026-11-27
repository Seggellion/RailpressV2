# frozen_string_literal: true

class CreateExtensionPlatformState < ActiveRecord::Migration[8.1]
  def change
    create_table :extension_installations do |table|
      table.references :site, null: false, foreign_key: true, index: false
      table.string :module_id, null: false, limit: 30
      table.string :version, null: false, limit: 80
      table.string :package_sha256, null: false, limit: 64
      table.string :manifest_sha256, null: false, limit: 64
      table.string :package_state, null: false, limit: 16
      table.boolean :enabled, null: false, default: false
      table.bigint :activation_generation, null: false
      table.bigint :engine_generation, null: false
      table.string :engine_fingerprint, null: false, limit: 64
      table.integer :module_schema, null: false
      table.integer :job_revision, null: false
      table.timestamps
      table.index %i[site_id module_id], unique: true, name: "idx_ext_install_site_module"
    end

    create_table :extension_install_requests do |table|
      table.references :site, null: false, foreign_key: true
      table.bigint :actor_id, null: false
      table.integer :actor_auth_version, null: false
      table.string :site_identity, null: false, limit: 36
      table.string :site_origin, null: false, limit: 255
      table.string :request_key, null: false, limit: 36
      table.string :operation, null: false, limit: 16
      table.string :module_id, null: false, limit: 30
      table.string :version, null: false, limit: 80
      table.string :package_sha256, null: false, limit: 64
      table.string :manifest_sha256, null: false, limit: 64
      table.string :plan_sha256, null: false, limit: 64
      table.string :core_version, null: false, limit: 80
      table.bigint :engine_generation, null: false
      table.string :engine_fingerprint, null: false, limit: 64
      table.bigint :activation_generation, null: false
      table.string :state, null: false, limit: 24
      table.bigint :receipt_sequence, null: false, default: 0
      table.string :receipt_sha256, limit: 64
      table.json :operator_receipt
      table.timestamps
      table.index :request_key, unique: true, name: "idx_ext_request_key"
    end

    create_table :extension_migration_records do |table|
      table.references :site, null: false, foreign_key: true, index: false
      table.string :module_id, null: false, limit: 30
      table.string :version, null: false, limit: 14
      table.string :sha256, null: false, limit: 64
      table.string :state, null: false, limit: 24
      table.timestamps
      table.index %i[site_id module_id version], unique: true, name: "idx_ext_migration_site_module_version"
    end
  end
end
