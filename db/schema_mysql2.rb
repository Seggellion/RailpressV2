# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_17_000001) do
  create_table "action_text_rich_texts", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.string "name", null: false
    t.text "body", size: :long
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["record_type", "record_id", "name"], name: "index_action_text_rich_texts_uniqueness", unique: true
  end

  create_table "active_storage_attachments", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "activity_events", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.bigint "actor_id"
    t.string "actor_name", limit: 40, null: false
    t.string "category", limit: 24, null: false
    t.string "action", limit: 80, null: false
    t.string "outcome", limit: 16, default: "succeeded", null: false
    t.string "subject_type", limit: 48
    t.bigint "subject_id"
    t.bigint "subject_owner_id"
    t.json "details", null: false
    t.datetime "created_at", null: false
    t.index ["actor_id"], name: "fk_rails_4a058a76d2"
    t.index ["site_id", "actor_id", "id"], name: "index_activity_events_on_site_id_and_actor_id_and_id"
    t.index ["site_id", "id"], name: "index_activity_events_on_site_id_and_id"
    t.index ["site_id", "subject_owner_id", "id"], name: "index_activity_events_on_site_id_and_subject_owner_id_and_id"
    t.index ["site_id"], name: "index_activity_events_on_site_id"
    t.check_constraint "`category` in (_utf8mb4'editorial',_utf8mb4'media',_utf8mb4'navigation',_utf8mb4'appearance',_utf8mb4'identity',_utf8mb4'security',_utf8mb4'seo',_utf8mb4'operations')", name: "activity_category_allowed"
    t.check_constraint "`outcome` in (_utf8mb4'succeeded',_utf8mb4'denied',_utf8mb4'failed',_utf8mb4'unsupported')", name: "activity_outcome_allowed"
  end

  create_table "authentication_throttles", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.string "key_digest", limit: 64, null: false
    t.datetime "window_started_at", null: false
    t.integer "attempts", default: 0, null: false
    t.index ["key_digest"], name: "index_authentication_throttles_on_key_digest", unique: true
    t.check_constraint "`attempts` >= 0", name: "auth_throttles_nonnegative"
  end

  create_table "content_previews", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "content_id", null: false
    t.bigint "actor_id", null: false
    t.string "token_digest", limit: 64, null: false
    t.integer "auth_version", null: false
    t.json "snapshot", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.json "deadline_binding"
    t.datetime "deadline_expired_at"
    t.index ["actor_id"], name: "index_content_previews_on_actor_id"
    t.index ["content_id"], name: "index_content_previews_on_content_id"
    t.index ["token_digest"], name: "index_content_previews_on_token_digest", unique: true
  end

  create_table "content_revisions", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "content_id", null: false
    t.bigint "actor_id"
    t.integer "number", null: false
    t.string "event", limit: 32, null: false
    t.json "snapshot", null: false
    t.datetime "created_at", null: false
    t.index ["actor_id"], name: "index_content_revisions_on_actor_id"
    t.index ["content_id", "number"], name: "index_content_revisions_on_content_id_and_number", unique: true
    t.index ["content_id"], name: "index_content_revisions_on_content_id"
  end

  create_table "content_terms", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "content_id", null: false
    t.bigint "term_id", null: false
    t.string "stage", limit: 8, null: false
    t.index ["content_id", "term_id", "stage"], name: "index_content_terms_on_content_id_and_term_id_and_stage", unique: true
    t.index ["content_id"], name: "index_content_terms_on_content_id"
    t.index ["term_id"], name: "index_content_terms_on_term_id"
    t.check_constraint "`stage` in (_utf8mb4'draft',_utf8mb4'live')", name: "content_term_stage"
  end

  create_table "contents", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.string "type", limit: 16, null: false
    t.string "title", limit: 200, null: false
    t.string "slug", limit: 160, null: false
    t.string "slug_key", limit: 64, null: false
    t.text "body", null: false
    t.text "excerpt"
    t.bigint "author_id", null: false
    t.string "status", limit: 16, default: "draft", null: false
    t.string "visibility", limit: 16, default: "public", null: false
    t.string "template_key", limit: 32, default: "standard", null: false
    t.string "meta_title", limit: 160
    t.string "meta_description", limit: 320
    t.bigint "featured_blob_id"
    t.string "published_visibility", limit: 16
    t.boolean "pending_review", default: false, null: false
    t.bigint "scheduled_by_id"
    t.datetime "scheduled_at"
    t.datetime "published_at"
    t.datetime "first_published_at"
    t.json "published_snapshot"
    t.boolean "home_page", default: false, null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "featured_media_id"
    t.json "blocks"
    t.json "media_details"
    t.datetime "public_updated_at"
    t.text "public_search_text"
    t.string "last_public_path", limit: 1024
    t.json "portable_metadata", null: false
    t.index ["author_id"], name: "index_contents_on_author_id"
    t.index ["featured_blob_id"], name: "index_contents_on_featured_blob_id"
    t.index ["featured_media_id"], name: "index_contents_on_featured_media_id"
    t.index ["scheduled_by_id"], name: "index_contents_on_scheduled_by_id"
    t.index ["status", "scheduled_at"], name: "index_contents_on_status_and_scheduled_at"
    t.index ["type", "slug_key"], name: "index_contents_on_type_and_slug_key", unique: true
    t.check_constraint "`lock_version` >= 0", name: "content_version"
    t.check_constraint "`status` in (_utf8mb4'draft',_utf8mb4'pending',_utf8mb4'scheduled',_utf8mb4'published',_utf8mb4'trashed')", name: "content_status"
    t.check_constraint "`template_key` in (_utf8mb4'standard',_utf8mb4'wide')", name: "content_template"
    t.check_constraint "`type` in (_utf8mb4'Page',_utf8mb4'Post')", name: "content_type"
    t.check_constraint "`visibility` in (_utf8mb4'public',_utf8mb4'private')", name: "content_visibility"
  end

  create_table "dashboard_draft_submissions", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.bigint "actor_id"
    t.bigint "content_id", null: false
    t.string "request_key", limit: 36, null: false
    t.string "request_digest", limit: 64, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "index_dashboard_draft_submissions_on_actor_id"
    t.index ["content_id"], name: "index_dashboard_draft_submissions_on_content_id"
    t.index ["site_id", "request_key"], name: "dashboard_submission_identity", unique: true
    t.index ["site_id"], name: "index_dashboard_draft_submissions_on_site_id"
  end

  create_table "import_batches", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.bigint "actor_id", null: false
    t.string "public_id", limit: 36, null: false
    t.string "idempotency_key", limit: 64, null: false
    t.bigint "approval_session_id", null: false
    t.integer "auth_version", null: false
    t.string "state", limit: 32, default: "queued", null: false
    t.string "archive_sha256", limit: 64, null: false
    t.bigint "archive_bytes", null: false
    t.integer "format_version"
    t.string "normalized_sha256", limit: 64
    t.json "manifest", null: false
    t.json "report", null: false
    t.json "decisions", null: false
    t.json "lease", null: false
    t.string "lease_token", limit: 32
    t.string "baseline_sha256", limit: 64
    t.integer "progress", default: 0, null: false
    t.integer "total", default: 0, null: false
    t.string "failure", limit: 200
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "index_import_batches_on_actor_id"
    t.index ["public_id"], name: "index_import_batches_on_public_id", unique: true
    t.index ["site_id", "idempotency_key"], name: "index_import_batches_on_site_id_and_idempotency_key", unique: true
    t.index ["site_id"], name: "index_import_batches_on_site_id"
    t.check_constraint "(`progress` >= 0) and (`total` >= 0) and (`archive_bytes` > 0)", name: "import_nonnegative_progress"
  end

  create_table "import_events", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "import_batch_id", null: false
    t.bigint "number", null: false
    t.string "event", limit: 64, null: false
    t.json "details", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["import_batch_id", "number"], name: "index_import_events_on_import_batch_id_and_number", unique: true
    t.index ["import_batch_id"], name: "index_import_events_on_import_batch_id"
  end

  create_table "import_items", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "import_batch_id", null: false
    t.string "source_ref", limit: 80, null: false
    t.string "kind", limit: 32, null: false
    t.string "state", limit: 32, default: "planned", null: false
    t.bigint "target_id"
    t.boolean "created_record", default: false, null: false
    t.string "source_sha256", limit: 64, null: false
    t.string "target_sha256", limit: 64
    t.json "details", null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["import_batch_id", "source_ref"], name: "index_import_items_on_import_batch_id_and_source_ref", unique: true
    t.index ["import_batch_id"], name: "index_import_items_on_import_batch_id"
    t.index ["kind", "target_id"], name: "index_import_items_on_kind_and_target_id"
  end

  create_table "media_assets", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.string "public_id", limit: 36, null: false
    t.bigint "author_id", null: false
    t.bigint "blob_id"
    t.bigint "thumbnail_blob_id"
    t.string "state", limit: 16, default: "ready", null: false
    t.string "filename", limit: 160, null: false
    t.string "title", limit: 200, null: false
    t.string "content_type", limit: 32, null: false
    t.string "source_sha256", limit: 64, null: false
    t.string "sha256", limit: 64, null: false
    t.string "thumbnail_sha256", limit: 64, null: false
    t.bigint "source_bytes", null: false
    t.bigint "byte_size", null: false
    t.integer "width", null: false
    t.integer "height", null: false
    t.integer "source_width", null: false
    t.integer "source_height", null: false
    t.string "alt_text", limit: 500, default: "", null: false
    t.boolean "decorative", default: false, null: false
    t.text "caption"
    t.text "attribution"
    t.text "license_notes"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.json "retained_objects"
    t.index ["author_id"], name: "index_media_assets_on_author_id"
    t.index ["blob_id"], name: "media_unique_blob", unique: true
    t.index ["public_id"], name: "index_media_assets_on_public_id", unique: true
    t.index ["thumbnail_blob_id"], name: "media_unique_thumbnail", unique: true
    t.check_constraint "((`state` = _utf8mb4'ready') and (`blob_id` is not null) and (`thumbnail_blob_id` is not null)) or (`state` = _utf8mb4'purging') or ((`state` = _utf8mb4'purged') and (`blob_id` is null) and (`thumbnail_blob_id` is null))", name: "media_object_state"
    t.check_constraint "(`lock_version` >= 0) and (`source_width` > 0) and (`source_height` > 0)", name: "media_source_bounds"
    t.check_constraint "(`width` > 0) and (`height` > 0) and (`byte_size` > 0) and (`source_bytes` > 0)", name: "media_dimensions"
    t.check_constraint "`content_type` = _utf8mb4'image/png'", name: "media_canonical_type"
    t.check_constraint "`state` in (_utf8mb4'ready',_utf8mb4'purging',_utf8mb4'purged')", name: "media_state"
  end

  create_table "media_references", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "media_asset_id", null: false
    t.bigint "content_id"
    t.bigint "content_revision_id"
    t.bigint "content_preview_id"
    t.string "stage", limit: 16, null: false
    t.bigint "theme_overlay_id"
    t.index ["content_id"], name: "index_media_references_on_content_id"
    t.index ["content_preview_id"], name: "index_media_references_on_content_preview_id"
    t.index ["content_revision_id"], name: "index_media_references_on_content_revision_id"
    t.index ["media_asset_id", "content_id", "stage"], name: "media_content_stage", unique: true
    t.index ["media_asset_id", "content_preview_id"], name: "media_preview", unique: true
    t.index ["media_asset_id", "content_revision_id"], name: "media_revision", unique: true
    t.index ["media_asset_id"], name: "index_media_references_on_media_asset_id"
    t.index ["theme_overlay_id", "media_asset_id"], name: "media_theme_overlay", unique: true
    t.index ["theme_overlay_id"], name: "index_media_references_on_theme_overlay_id"
    t.check_constraint "((`theme_overlay_id` is null) and (`content_id` is not null) and (`content_revision_id` is null) and (`content_preview_id` is null) and (`stage` in (_utf8mb4'draft',_utf8mb4'live'))) or ((`theme_overlay_id` is null) and (`content_id` is null) and (`content_revision_id` is not null) and (`content_preview_id` is null) and (`stage` = _utf8mb4'revision')) or ((`theme_overlay_id` is null) and (`content_id` is null) and (`content_revision_id` is null) and (`content_preview_id` is not null) and (`stage` = _utf8mb4'preview')) or ((`theme_overlay_id` is not null) and (`content_id` is null) and (`content_revision_id` is null) and (`content_preview_id` is null) and (`stage` = _utf8mb4'theme'))", name: "media_reference_owner"
  end

  create_table "media_uploads", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "author_id", null: false
    t.string "state", limit: 16, default: "processing", null: false
    t.string "reason", limit: 32
    t.bigint "byte_size", default: 0, null: false
    t.string "source_sha256", limit: 64
    t.json "storage_keys"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_media_uploads_on_author_id"
    t.check_constraint "`state` in (_utf8mb4'processing',_utf8mb4'accepted',_utf8mb4'rejected')", name: "media_upload_state"
  end

  create_table "member_challenges", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "member_session_id"
    t.bigint "site_id", null: false
    t.bigint "member_id"
    t.string "purpose", limit: 16, null: false
    t.string "email", limit: 254, null: false
    t.string "email_key", limit: 64, null: false
    t.string "token_digest", limit: 64, null: false
    t.string "state", limit: 16, default: "pending", null: false
    t.integer "policy_version", null: false
    t.integer "auth_version"
    t.datetime "expires_at", null: false
    t.json "deadline_binding"
    t.datetime "deadline_expired_at"
    t.datetime "used_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "browser_digest", limit: 64
    t.index ["member_id"], name: "index_member_challenges_on_member_id"
    t.index ["member_session_id"], name: "index_member_challenges_on_member_session_id"
    t.index ["site_id"], name: "index_member_challenges_on_site_id"
    t.index ["token_digest"], name: "index_member_challenges_on_token_digest", unique: true
    t.check_constraint "(`purpose` in (_utf8mb4'signin',_utf8mb4'change_email')) and (`state` in (_utf8mb4'pending',_utf8mb4'delivered',_utf8mb4'failed',_utf8mb4'consumed'))", name: "member_challenge_state"
  end

  create_table "member_identities", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "member_id", null: false
    t.string "provider", limit: 16, null: false
    t.string "subject", limit: 32, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["member_id", "provider"], name: "index_member_identities_on_member_id_and_provider", unique: true
    t.index ["member_id"], name: "index_member_identities_on_member_id"
    t.index ["provider", "subject"], name: "index_member_identities_on_provider_and_subject", unique: true
    t.check_constraint "`provider` = _utf8mb4'discord'", name: "member_identity_provider"
  end

  create_table "member_oauth_attempts", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.bigint "member_session_id"
    t.string "purpose", limit: 16, null: false
    t.string "state_digest", limit: 64, null: false
    t.string "browser_digest", limit: 64, null: false
    t.string "code_digest", limit: 64
    t.text "verifier_ciphertext", null: false
    t.string "callback", limit: 512, null: false
    t.integer "policy_version", null: false
    t.datetime "expires_at", null: false
    t.json "deadline_binding"
    t.datetime "deadline_expired_at"
    t.datetime "used_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "provider_fingerprint", limit: 64
    t.index ["code_digest"], name: "index_member_oauth_attempts_on_code_digest", unique: true
    t.index ["member_session_id"], name: "index_member_oauth_attempts_on_member_session_id"
    t.index ["site_id"], name: "index_member_oauth_attempts_on_site_id"
    t.index ["state_digest"], name: "index_member_oauth_attempts_on_state_digest", unique: true
    t.check_constraint "`purpose` in (_utf8mb4'signin',_utf8mb4'link')", name: "member_oauth_purpose"
  end

  create_table "member_sessions", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "member_id", null: false
    t.integer "auth_version", null: false
    t.string "authentication_method", limit: 16, null: false
    t.string "token_digest", limit: 64, null: false
    t.datetime "expires_at", null: false
    t.json "deadline_binding"
    t.datetime "deadline_expired_at"
    t.json "proof_binding", null: false
    t.datetime "proof_expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["member_id"], name: "index_member_sessions_on_member_id"
    t.index ["token_digest"], name: "index_member_sessions_on_token_digest", unique: true
    t.check_constraint "(`authentication_method` in (_utf8mb4'email',_utf8mb4'discord')) and (`auth_version` >= 0)", name: "member_session_authority"
  end

  create_table "member_throttles", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.string "key_digest", limit: 64, null: false
    t.integer "attempts", default: 0, null: false
    t.json "binding", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key_digest"], name: "index_member_throttles_on_key_digest", unique: true
    t.check_constraint "`attempts` >= 0", name: "member_throttle_count"
  end

  create_table "members", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.string "public_id", limit: 36, null: false
    t.string "email", limit: 254
    t.string "email_key", limit: 64
    t.datetime "email_verified_at"
    t.string "email_proof", limit: 16
    t.string "status", limit: 16, default: "active", null: false
    t.integer "auth_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["public_id"], name: "index_members_on_public_id", unique: true
    t.index ["site_id", "email_key"], name: "index_members_on_site_id_and_email_key", unique: true
    t.index ["site_id"], name: "index_members_on_site_id"
    t.check_constraint "((`email` is null) and (`email_key` is null) and (`email_verified_at` is null) and (`email_proof` is null)) or ((`email` is not null) and (`email_key` is not null) and (`email_verified_at` is not null) and (`email_proof` in (_utf8mb4'mailbox',_utf8mb4'discord')))", name: "member_mailbox_proof"
    t.check_constraint "(`status` in (_utf8mb4'active',_utf8mb4'closed')) and (`auth_version` >= 0)", name: "member_authority"
  end

  create_table "menu_items", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "menu_id", null: false
    t.string "key", limit: 32, null: false
    t.string "parent_key", limit: 32
    t.string "parent_scope", limit: 32, null: false
    t.integer "position", null: false
    t.string "label", limit: 120, null: false
    t.string "kind", limit: 16, null: false
    t.bigint "content_id"
    t.bigint "term_id"
    t.string "url", limit: 2048
    t.index ["content_id"], name: "index_menu_items_on_content_id"
    t.index ["menu_id", "key"], name: "index_menu_items_on_menu_id_and_key", unique: true
    t.index ["menu_id", "parent_key"], name: "menu_own_parent"
    t.index ["menu_id", "parent_scope", "position"], name: "menu_sibling_order", unique: true
    t.index ["menu_id"], name: "index_menu_items_on_menu_id"
    t.index ["term_id"], name: "index_menu_items_on_term_id"
    t.check_constraint "((`kind` in (_utf8mb4'Page',_utf8mb4'Post')) and (`content_id` is not null) and (`term_id` is null) and (`url` is null)) or ((`kind` = _utf8mb4'Term') and (`content_id` is null) and (`term_id` is not null) and (`url` is null)) or ((`kind` = _utf8mb4'Custom') and (`content_id` is null) and (`term_id` is null) and (`url` is not null))", name: "menu_typed_target"
    t.check_constraint "((`parent_key` is null) and (`parent_scope` = _utf8mb4'root')) or ((`parent_key` is not null) and (`parent_scope` = `parent_key`) and (`parent_key` <> `key`))", name: "menu_parent_scope"
    t.check_constraint "(`position` >= 0) and (`position` < 30)", name: "menu_position"
  end

  create_table "menu_locations", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.string "theme_key", limit: 40, null: false
    t.string "key", limit: 32, null: false
    t.bigint "draft_menu_id"
    t.bigint "published_menu_id"
    t.index ["site_id", "draft_menu_id"], name: "menu_draft_site"
    t.index ["site_id", "published_menu_id"], name: "menu_live_site"
    t.index ["site_id", "theme_key", "key"], name: "menu_location_identity", unique: true
    t.index ["site_id"], name: "index_menu_locations_on_site_id"
  end

  create_table "menu_revisions", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "menu_id", null: false
    t.bigint "actor_id", null: false
    t.integer "number", null: false
    t.integer "state_version", null: false
    t.string "operation", limit: 24, null: false
    t.json "snapshot", null: false
    t.json "before_snapshot", null: false
    t.datetime "created_at", null: false
    t.index ["actor_id"], name: "index_menu_revisions_on_actor_id"
    t.index ["menu_id", "id"], name: "index_menu_revisions_on_menu_id_and_id", unique: true
    t.index ["menu_id", "number"], name: "index_menu_revisions_on_menu_id_and_number", unique: true
    t.index ["menu_id"], name: "index_menu_revisions_on_menu_id"
    t.check_constraint "(`number` > 0) and (`state_version` > 0)", name: "menu_revision_number"
  end

  create_table "menus", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.string "name", limit: 100, null: false
    t.string "status", limit: 16, default: "active", null: false
    t.integer "lock_version", default: 0, null: false
    t.bigint "published_revision_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["id", "published_revision_id"], name: "menu_own_publication"
    t.index ["site_id", "id"], name: "index_menus_on_site_id_and_id", unique: true
    t.index ["site_id"], name: "index_menus_on_site_id"
    t.check_constraint "(`lock_version` >= 0) and (`status` in (_utf8mb4'active',_utf8mb4'deleted'))", name: "menu_state"
  end

  create_table "navigation_previews", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "menu_id", null: false
    t.bigint "actor_id", null: false
    t.integer "auth_version", null: false
    t.integer "menu_version", null: false
    t.string "token_digest", limit: 64, null: false
    t.string "session_digest", limit: 64, null: false
    t.datetime "expires_at", null: false
    t.json "deadline_binding"
    t.datetime "deadline_expired_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "index_navigation_previews_on_actor_id"
    t.index ["menu_id"], name: "index_navigation_previews_on_menu_id"
    t.index ["token_digest"], name: "index_navigation_previews_on_token_digest", unique: true
  end

  create_table "navigation_states", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["site_id"], name: "index_navigation_states_on_site_id", unique: true
    t.check_constraint "`lock_version` >= 0", name: "navigation_version"
  end

  create_table "official_news_reviews", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "content_id", null: false
    t.bigint "actor_id"
    t.bigint "publication_revision_id", null: false
    t.string "public_id", limit: 36, null: false
    t.string "publication_digest", limit: 64, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "index_official_news_reviews_on_actor_id"
    t.index ["content_id"], name: "index_official_news_reviews_on_content_id", unique: true
    t.index ["public_id"], name: "index_official_news_reviews_on_public_id", unique: true
    t.index ["publication_revision_id"], name: "index_official_news_reviews_on_publication_revision_id"
  end

  create_table "official_news_states", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.boolean "enabled", default: false, null: false
    t.boolean "provider_enabled", default: false, null: false
    t.integer "generation", default: 0, null: false
    t.integer "lock_version", default: 0, null: false
    t.json "payload"
    t.string "etag", limit: 200
    t.string "last_modified", limit: 100
    t.datetime "retrieved_at"
    t.json "fresh_binding"
    t.json "retention_binding"
    t.json "wait_binding"
    t.json "lease_binding"
    t.string "lease_key", limit: 36
    t.integer "failures", default: 0, null: false
    t.string "last_error", limit: 64
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["site_id"], name: "index_official_news_states_on_site_id", unique: true
    t.check_constraint "(`generation` >= 0) and (`lock_version` >= 0) and (`failures` >= 0) and (`failures` <= 16)", name: "official_news_bounds"
  end

  create_table "password_resets", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "token_digest", limit: 64, null: false
    t.integer "auth_version", null: false
    t.datetime "expires_at", null: false
    t.datetime "used_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.json "deadline_binding"
    t.datetime "deadline_expired_at"
    t.index ["token_digest"], name: "index_password_resets_on_token_digest", unique: true
    t.index ["user_id"], name: "index_password_resets_on_user_id"
  end

  create_table "platform_states", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.string "scope_name", null: false
    t.string "key_name", null: false
    t.string "scope_digest", limit: 64, null: false
    t.string "key_digest", limit: 64, null: false
    t.json "payload", null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["scope_digest", "key_digest"], name: "index_platform_states_identity", unique: true
    t.check_constraint "`lock_version` >= 0", name: "platform_states_lock_version_nonnegative"
  end

  create_table "portability_exports", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.bigint "actor_id", null: false
    t.string "public_id", limit: 36, null: false
    t.bigint "approval_session_id", null: false
    t.integer "auth_version", null: false
    t.string "state", limit: 32, default: "queued", null: false
    t.json "scope", null: false
    t.json "report", null: false
    t.string "archive_sha256", limit: 64
    t.bigint "archive_bytes"
    t.string "failure", limit: 200
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "index_portability_exports_on_actor_id"
    t.index ["public_id"], name: "index_portability_exports_on_public_id", unique: true
    t.index ["site_id"], name: "index_portability_exports_on_site_id"
  end

  create_table "portability_identities", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.string "kind", limit: 32, null: false
    t.string "record_key", limit: 120, null: false
    t.string "public_id", limit: 36, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["public_id"], name: "index_portability_identities_on_public_id", unique: true
    t.index ["site_id", "kind", "record_key"], name: "portable_record_identity", unique: true
    t.index ["site_id"], name: "index_portability_identities_on_site_id"
  end

  create_table "portability_states", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.string "public_id", limit: 36, null: false
    t.bigint "active_import_id"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active_import_id"], name: "fk_rails_05ef2b2317"
    t.index ["public_id"], name: "index_portability_states_on_public_id", unique: true
    t.index ["site_id"], name: "index_portability_states_on_site_id", unique: true
  end

  create_table "readiness_runs", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.bigint "actor_id"
    t.integer "auth_version", null: false
    t.string "state", limit: 16, default: "pending", null: false
    t.integer "active_slot"
    t.integer "lock_version", default: 0, null: false
    t.json "findings", null: false
    t.json "fingerprint", null: false
    t.json "timing", null: false
    t.string "failure_code", limit: 64
    t.datetime "started_at"
    t.datetime "observed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "fk_rails_402f671272"
    t.index ["site_id", "active_slot"], name: "index_readiness_runs_on_site_id_and_active_slot", unique: true
    t.index ["site_id"], name: "index_readiness_runs_on_site_id"
    t.check_constraint "((`state` in (_utf8mb4'pending',_utf8mb4'running')) and (`active_slot` is not null)) or ((`state` in (_utf8mb4'complete',_utf8mb4'failed',_utf8mb4'cancelled')) and (`active_slot` is null))", name: "readiness_slot_state"
    t.check_constraint "(`active_slot` is null) or (`active_slot` = 1)", name: "readiness_single_slot"
    t.check_constraint "`state` in (_utf8mb4'pending',_utf8mb4'running',_utf8mb4'complete',_utf8mb4'failed',_utf8mb4'cancelled')", name: "readiness_state_allowed"
  end

  create_table "redirects", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.text "source_path", null: false
    t.string "source_digest", limit: 64, null: false
    t.bigint "target_content_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["source_digest"], name: "index_redirects_on_source_digest", unique: true
    t.index ["target_content_id"], name: "index_redirects_on_target_content_id"
  end

  create_table "release_requests", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.bigint "actor_id", null: false
    t.string "request_key", limit: 36, null: false
    t.string "release_digest", limit: 64, null: false
    t.string "operation", limit: 16, null: false
    t.integer "actor_auth_version", null: false
    t.json "receipt"
    t.integer "receipt_revision", default: 0, null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "index_release_requests_on_actor_id"
    t.index ["request_key"], name: "index_release_requests_on_request_key", unique: true
    t.index ["site_id"], name: "index_release_requests_on_site_id"
  end

  create_table "seo_diagnostic_runs", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "requester_id", null: false
    t.string "active_key", limit: 32
    t.string "status", limit: 16, default: "pending", null: false
    t.string "mode", limit: 16, null: false
    t.string "origin", null: false
    t.bigint "generation", null: false
    t.json "summary", null: false
    t.datetime "started_at"
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active_key"], name: "index_seo_diagnostic_runs_on_active_key", unique: true
    t.index ["requester_id"], name: "index_seo_diagnostic_runs_on_requester_id"
    t.check_constraint "((`status` in (_utf8mb4'pending',_utf8mb4'running')) and (`active_key` is not null) and (`active_key` = _utf8mb4'site') and (`finished_at` is null)) or ((`status` in (_utf8mb4'completed',_utf8mb4'failed',_utf8mb4'cancelled')) and (`active_key` is null) and (`finished_at` is not null))", name: "seo_run_lifecycle"
    t.check_constraint "`generation` >= 0", name: "seo_run_generation"
    t.check_constraint "`mode` in (_utf8mb4'offline',_utf8mb4'http')", name: "seo_run_mode"
  end

  create_table "seo_diagnostic_targets", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "seo_diagnostic_run_id", null: false
    t.text "url", null: false
    t.string "url_digest", limit: 64, null: false
    t.string "family", limit: 24, null: false
    t.integer "position", null: false
    t.json "result", null: false
    t.datetime "checked_at"
    t.index ["seo_diagnostic_run_id", "position"], name: "seo_target_position", unique: true
    t.index ["seo_diagnostic_run_id", "url_digest"], name: "seo_target_digest", unique: true
    t.index ["seo_diagnostic_run_id"], name: "index_seo_diagnostic_targets_on_seo_diagnostic_run_id"
    t.check_constraint "`position` >= 0", name: "seo_target_position_nonnegative"
  end

  create_table "sites", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.integer "singleton_key", default: 1, null: false
    t.string "install_id", limit: 36, null: false
    t.bigint "owner_id", null: false
    t.string "title", null: false
    t.string "tagline", default: "", null: false
    t.string "canonical_origin", null: false
    t.string "locale", limit: 16, default: "en", null: false
    t.string "timezone", limit: 80, default: "Etc/UTC", null: false
    t.boolean "indexing_enabled", default: false, null: false
    t.string "home_mode", limit: 16, default: "static", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "homepage_content_id"
    t.bigint "seo_generation", default: 0, null: false
    t.datetime "seo_changed_at"
    t.string "organization_name", limit: 200
    t.string "membership_mode", limit: 16, default: "disabled", null: false
    t.boolean "member_registration_enabled", default: false, null: false
    t.boolean "member_email_required", default: true, null: false
    t.integer "membership_version", default: 0, null: false
    t.boolean "privacy_first_anonymous", default: false, null: false
    t.integer "privacy_revision", default: 0, null: false
    t.index ["homepage_content_id"], name: "index_sites_on_homepage_content_id"
    t.index ["install_id"], name: "index_sites_on_install_id", unique: true
    t.index ["owner_id"], name: "index_sites_on_owner_id"
    t.index ["singleton_key"], name: "index_sites_on_singleton_key", unique: true
    t.check_constraint "(`membership_mode` <> _utf8mb4'disabled') or (`member_registration_enabled` = false)", name: "disabled_membership_closed"
    t.check_constraint "(`membership_mode` in (_utf8mb4'disabled',_utf8mb4'email',_utf8mb4'discord',_utf8mb4'both')) and (`membership_version` >= 0)", name: "site_membership_policy"
    t.check_constraint "`home_mode` in (_utf8mb4'static',_utf8mb4'blog')", name: "sites_valid_home_mode"
    t.check_constraint "`privacy_revision` >= 0", name: "site_privacy_revision_nonnegative"
    t.check_constraint "`seo_generation` >= 0", name: "seo_generation_nonnegative"
    t.check_constraint "`singleton_key` = 1", name: "sites_singleton"
  end

  create_table "solid_queue_batch_executions", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "batch_id", null: false
    t.datetime "created_at", null: false
    t.index ["batch_id"], name: "index_solid_queue_batch_executions_on_batch_id"
    t.index ["job_id"], name: "index_solid_queue_batch_executions_on_job_id", unique: true
  end

  create_table "solid_queue_batches", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.string "active_job_batch_id"
    t.string "description"
    t.text "on_finish"
    t.text "on_success"
    t.text "on_failure"
    t.text "metadata"
    t.integer "total_jobs", default: 0, null: false
    t.integer "completed_jobs", default: 0, null: false
    t.integer "failed_jobs", default: 0, null: false
    t.datetime "enqueued_at"
    t.datetime "finished_at"
    t.datetime "failed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active_job_batch_id"], name: "index_solid_queue_batches_on_active_job_batch_id", unique: true
    t.index ["finished_at"], name: "index_solid_queue_batches_on_finished_at"
  end

  create_table "solid_queue_blocked_executions", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.string "concurrency_key", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.text "error"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.string "queue_name", null: false
    t.string "class_name", null: false
    t.text "arguments"
    t.integer "priority", default: 0, null: false
    t.string "active_job_id"
    t.datetime "scheduled_at"
    t.datetime "finished_at"
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "batch_id"
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["batch_id"], name: "index_solid_queue_jobs_on_batch_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.string "queue_name", null: false
    t.datetime "created_at", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.bigint "supervisor_id"
    t.integer "pid", null: false
    t.string "hostname"
    t.text "metadata"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "task_key", null: false
    t.datetime "run_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.string "key", null: false
    t.string "schedule", null: false
    t.string "command", limit: 2048
    t.string "class_name"
    t.text "arguments"
    t.string "queue_name"
    t.integer "priority", default: 0
    t.boolean "static", default: true, null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "scheduled_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.string "key", null: false
    t.integer "value", default: 1, null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "taxonomies", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.string "kind", limit: 16, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["kind"], name: "index_taxonomies_on_kind", unique: true
    t.check_constraint "`kind` in (_utf8mb4'category',_utf8mb4'tag')", name: "taxonomy_kind"
  end

  create_table "terms", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "taxonomy_id", null: false
    t.string "name", limit: 100, null: false
    t.string "slug", limit: 160, null: false
    t.string "slug_key", limit: 64, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["taxonomy_id", "slug_key"], name: "index_terms_on_taxonomy_id_and_slug_key", unique: true
    t.index ["taxonomy_id"], name: "index_terms_on_taxonomy_id"
  end

  create_table "theme_installations", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.string "theme_key", limit: 40, null: false
    t.string "version", limit: 80, null: false
    t.string "digest", limit: 64, null: false
    t.string "status", limit: 16, default: "validated", null: false
    t.json "manifest", null: false
    t.json "smoke_report", null: false
    t.datetime "ever_active_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["site_id", "theme_key", "version", "digest"], name: "theme_package_identity", unique: true
    t.index ["site_id"], name: "index_theme_installations_on_site_id"
    t.check_constraint "`status` in (_utf8mb4'validated',_utf8mb4'removed')", name: "theme_install_status"
  end

  create_table "theme_overlays", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "theme_installation_id", null: false
    t.bigint "author_id", null: false
    t.integer "number", null: false
    t.json "options", null: false
    t.json "media_details", null: false
    t.datetime "created_at", null: false
    t.index ["author_id"], name: "index_theme_overlays_on_author_id"
    t.index ["theme_installation_id", "number"], name: "theme_overlay_version", unique: true
    t.index ["theme_installation_id"], name: "index_theme_overlays_on_theme_installation_id"
    t.check_constraint "`number` > 0", name: "theme_overlay_positive"
  end

  create_table "theme_previews", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "actor_id", null: false
    t.bigint "theme_installation_id", null: false
    t.bigint "theme_overlay_id", null: false
    t.string "token_digest", limit: 64, null: false
    t.string "session_digest", limit: 64, null: false
    t.integer "auth_version", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.json "deadline_binding"
    t.datetime "deadline_expired_at"
    t.index ["actor_id"], name: "index_theme_previews_on_actor_id"
    t.index ["theme_installation_id"], name: "index_theme_previews_on_theme_installation_id"
    t.index ["theme_overlay_id"], name: "index_theme_previews_on_theme_overlay_id"
    t.index ["token_digest"], name: "index_theme_previews_on_token_digest", unique: true
  end

  create_table "theme_states", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "site_id", null: false
    t.string "default_key", limit: 40, default: "dusk", null: false
    t.bigint "active_installation_id"
    t.bigint "previous_installation_id"
    t.bigint "active_overlay_id"
    t.bigint "previous_overlay_id"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active_installation_id"], name: "index_theme_states_on_active_installation_id"
    t.index ["active_overlay_id"], name: "index_theme_states_on_active_overlay_id"
    t.index ["previous_installation_id"], name: "index_theme_states_on_previous_installation_id"
    t.index ["previous_overlay_id"], name: "index_theme_states_on_previous_overlay_id"
    t.index ["site_id"], name: "index_theme_states_on_site_id", unique: true
    t.check_constraint "((`active_installation_id` is null) and (`active_overlay_id` is null)) or ((`active_installation_id` is not null) and (`active_overlay_id` is not null))", name: "theme_active_pair"
    t.check_constraint "(`default_key` = _utf8mb4'dusk') and (`lock_version` >= 0)", name: "theme_default_and_version"
  end

  create_table "user_sessions", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "token_digest", limit: 64, null: false
    t.integer "auth_version", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.json "deadline_binding"
    t.datetime "deadline_expired_at"
    t.index ["token_digest"], name: "index_user_sessions_on_token_digest", unique: true
    t.index ["user_id"], name: "index_user_sessions_on_user_id"
  end

  create_table "users", charset: "utf8mb4", collation: "utf8mb4_0900_bin", force: :cascade do |t|
    t.string "username", limit: 40, null: false
    t.string "email", limit: 254, null: false
    t.string "username_key", limit: 64, null: false
    t.string "email_key", limit: 64, null: false
    t.string "password_digest", null: false
    t.string "role", limit: 16, null: false
    t.integer "auth_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email_key"], name: "index_users_on_email_key", unique: true
    t.index ["username_key"], name: "index_users_on_username_key", unique: true
    t.check_constraint "`auth_version` >= 0", name: "users_nonnegative_auth_version"
    t.check_constraint "`role` in (_utf8mb4'owner',_utf8mb4'administrator',_utf8mb4'editor',_utf8mb4'author')", name: "users_valid_role"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "activity_events", "sites", on_delete: :cascade
  add_foreign_key "activity_events", "users", column: "actor_id", on_delete: :nullify
  add_foreign_key "content_previews", "contents"
  add_foreign_key "content_previews", "users", column: "actor_id"
  add_foreign_key "content_revisions", "contents"
  add_foreign_key "content_revisions", "users", column: "actor_id"
  add_foreign_key "content_terms", "contents"
  add_foreign_key "content_terms", "terms"
  add_foreign_key "contents", "active_storage_blobs", column: "featured_blob_id"
  add_foreign_key "contents", "media_assets", column: "featured_media_id"
  add_foreign_key "contents", "users", column: "author_id"
  add_foreign_key "contents", "users", column: "scheduled_by_id"
  add_foreign_key "dashboard_draft_submissions", "contents"
  add_foreign_key "dashboard_draft_submissions", "sites"
  add_foreign_key "dashboard_draft_submissions", "users", column: "actor_id", on_delete: :nullify
  add_foreign_key "import_batches", "sites"
  add_foreign_key "import_batches", "users", column: "actor_id"
  add_foreign_key "import_events", "import_batches"
  add_foreign_key "import_items", "import_batches"
  add_foreign_key "media_assets", "active_storage_blobs", column: "blob_id"
  add_foreign_key "media_assets", "active_storage_blobs", column: "thumbnail_blob_id"
  add_foreign_key "media_assets", "users", column: "author_id"
  add_foreign_key "media_references", "content_previews"
  add_foreign_key "media_references", "content_revisions"
  add_foreign_key "media_references", "contents"
  add_foreign_key "media_references", "media_assets"
  add_foreign_key "media_references", "theme_overlays"
  add_foreign_key "media_uploads", "users", column: "author_id"
  add_foreign_key "member_challenges", "member_sessions", on_delete: :nullify
  add_foreign_key "member_challenges", "members"
  add_foreign_key "member_challenges", "sites"
  add_foreign_key "member_identities", "members"
  add_foreign_key "member_oauth_attempts", "member_sessions"
  add_foreign_key "member_oauth_attempts", "sites"
  add_foreign_key "member_sessions", "members"
  add_foreign_key "members", "sites"
  add_foreign_key "menu_items", "contents"
  add_foreign_key "menu_items", "menu_items", column: ["menu_id", "parent_key"], primary_key: ["menu_id", "key"], name: "menu_own_parent"
  add_foreign_key "menu_items", "menus"
  add_foreign_key "menu_items", "terms"
  add_foreign_key "menu_locations", "menus", column: ["site_id", "draft_menu_id"], primary_key: ["site_id", "id"], name: "menu_draft_site"
  add_foreign_key "menu_locations", "menus", column: ["site_id", "published_menu_id"], primary_key: ["site_id", "id"], name: "menu_live_site"
  add_foreign_key "menu_locations", "sites"
  add_foreign_key "menu_revisions", "menus"
  add_foreign_key "menu_revisions", "users", column: "actor_id"
  add_foreign_key "menus", "menu_revisions", column: ["id", "published_revision_id"], primary_key: ["menu_id", "id"], name: "menu_own_publication"
  add_foreign_key "menus", "sites"
  add_foreign_key "navigation_previews", "menus"
  add_foreign_key "navigation_previews", "users", column: "actor_id"
  add_foreign_key "navigation_states", "sites"
  add_foreign_key "official_news_reviews", "content_revisions", column: "publication_revision_id"
  add_foreign_key "official_news_reviews", "contents"
  add_foreign_key "official_news_reviews", "users", column: "actor_id", on_delete: :nullify
  add_foreign_key "official_news_states", "sites"
  add_foreign_key "password_resets", "users", on_delete: :cascade
  add_foreign_key "portability_exports", "sites"
  add_foreign_key "portability_exports", "users", column: "actor_id"
  add_foreign_key "portability_identities", "sites"
  add_foreign_key "portability_states", "import_batches", column: "active_import_id"
  add_foreign_key "portability_states", "sites"
  add_foreign_key "readiness_runs", "sites", on_delete: :cascade
  add_foreign_key "readiness_runs", "users", column: "actor_id", on_delete: :nullify
  add_foreign_key "redirects", "contents", column: "target_content_id", on_delete: :nullify
  add_foreign_key "release_requests", "sites"
  add_foreign_key "release_requests", "users", column: "actor_id"
  add_foreign_key "seo_diagnostic_runs", "users", column: "requester_id"
  add_foreign_key "seo_diagnostic_targets", "seo_diagnostic_runs"
  add_foreign_key "sites", "contents", column: "homepage_content_id"
  add_foreign_key "sites", "users", column: "owner_id"
  add_foreign_key "solid_queue_batch_executions", "solid_queue_batches", column: "batch_id", on_delete: :cascade
  add_foreign_key "solid_queue_batch_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "terms", "taxonomies"
  add_foreign_key "theme_installations", "sites"
  add_foreign_key "theme_overlays", "theme_installations"
  add_foreign_key "theme_overlays", "users", column: "author_id"
  add_foreign_key "theme_previews", "theme_installations"
  add_foreign_key "theme_previews", "theme_overlays"
  add_foreign_key "theme_previews", "users", column: "actor_id"
  add_foreign_key "theme_states", "sites"
  add_foreign_key "theme_states", "theme_installations", column: "active_installation_id"
  add_foreign_key "theme_states", "theme_installations", column: "previous_installation_id"
  add_foreign_key "theme_states", "theme_overlays", column: "active_overlay_id"
  add_foreign_key "theme_states", "theme_overlays", column: "previous_overlay_id"
  add_foreign_key "user_sessions", "users", on_delete: :cascade
end
