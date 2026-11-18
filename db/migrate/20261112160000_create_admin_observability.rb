class CreateAdminObservability < ActiveRecord::Migration[8.1]
  def change
    create_table :activity_events do |t|
      t.references :site, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :actor_id
      t.string :actor_name, null: false, limit: 40
      t.string :category, null: false, limit: 24
      t.string :action, null: false, limit: 80
      t.string :outcome, null: false, limit: 16, default: "succeeded"
      t.string :subject_type, limit: 48
      t.bigint :subject_id
      t.bigint :subject_owner_id
      t.json :details, null: false
      t.datetime :created_at, null: false
    end
    add_foreign_key :activity_events, :users, column: :actor_id, on_delete: :nullify
    add_index :activity_events, [ :site_id, :id ]
    add_index :activity_events, [ :site_id, :actor_id, :id ]
    add_index :activity_events, [ :site_id, :subject_owner_id, :id ]
    add_check_constraint :activity_events, "outcome IN ('succeeded','denied','failed','unsupported')", name: "activity_outcome_allowed"
    add_check_constraint :activity_events, "category IN ('editorial','media','navigation','appearance','identity','security','seo','operations')", name: "activity_category_allowed"

    create_table :readiness_runs do |t|
      t.references :site, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :actor_id
      t.integer :auth_version, null: false
      t.string :state, null: false, default: "pending", limit: 16
      t.integer :active_slot
      t.integer :lock_version, null: false, default: 0
      t.json :findings, null: false
      t.json :fingerprint, null: false
      t.json :timing, null: false
      t.string :failure_code, limit: 64
      t.datetime :started_at
      t.datetime :observed_at
      t.timestamps
    end
    add_foreign_key :readiness_runs, :users, column: :actor_id, on_delete: :nullify
    add_index :readiness_runs, [ :site_id, :active_slot ], unique: true
    add_check_constraint :readiness_runs, "state IN ('pending','running','complete','failed','cancelled')", name: "readiness_state_allowed"
    add_check_constraint :readiness_runs, "active_slot IS NULL OR active_slot = 1", name: "readiness_single_slot"
    add_check_constraint :readiness_runs, "(state IN ('pending','running') AND active_slot IS NOT NULL) OR (state IN ('complete','failed','cancelled') AND active_slot IS NULL)", name: "readiness_slot_state"
  end
end
