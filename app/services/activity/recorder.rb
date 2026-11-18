module Activity
  module Recorder
    class Unavailable < StandardError; end
    LIMIT = 1000
    RETENTION = 90.days
    SUBJECTS = %w[Site User Content MediaAsset Menu ThemeInstallation ThemeOverlay ReadinessRun Seo::DiagnosticRun PortabilityExport ImportBatch].freeze
    EVENTS = {
      "content" => [ "editorial", %w[create save submit publish schedule unpublish trash restore restore_revision scheduled_publish schedule_cancelled reassign] ],
      "media" => [ "media", %w[upload update purge] ],
      "menu" => [ "navigation", %w[create rename add update remove move reorder reparent assign publish undo delete import_tree] ],
      "portability" => [ "operations", %w[export_requested export_downloaded import_received stage_approved activation_approved reversal_approved approval_renewed] ],
      "theme" => [ "appearance", %w[stage overlay preview activate revert remove] ],
      "identity" => [ "identity", %w[user_created role_changed user_removed site_updated membership_configured] ],
      "security" => [ "security", %w[login logout login_failed rate_limited password_changed denied] ],
      "seo" => [ "seo", %w[requested] ],
      "release" => [ "operations", %w[unsupported requested completed checks] ],
      "export" => [ "operations", %w[manifest] ],
      "readiness" => [ "operations", %w[requested completed cancelled] ],
      "news" => [ "operations", %w[enable disable clear refresh provider_enable provider_disable reviewed] ]
    }.freeze
    DETAIL_KEYS = %w[content_kind state revision from_role to_role previous_author_id new_author_id reason operation selection version digest run_state].freeze
    module_function
    def record!(actor:, action:, subject: nil, owner_id: nil, outcome: "succeeded", details: {})
      domain, verb = action.split(".", 2)
      category, verbs = EVENTS.fetch(domain) { raise ArgumentError, "Unknown activity action" }
      raise ArgumentError, "Unknown activity action" unless verbs.include?(verb)
      safe = details.to_h.stringify_keys.slice(*DETAIL_KEYS).each_with_object({}) do |(key, value), result|
        next unless [ String, Integer, TrueClass, FalseClass, NilClass ].any? { |kind| value.is_a?(kind) }
        next if value.is_a?(String) && (!value.valid_encoding? || value.include?("://") || value.match?(/[\x00-\x1f]/))
        result[key] = value.is_a?(String) ? value.first(100) : value
      end
      ActivityEvent.transaction(requires_new: true) do
        site = Site.find_by!(singleton_key: 1)
        site.lock!
        type = subject&.class&.base_class&.name
        raise ArgumentError, "Unknown activity subject" if type && !SUBJECTS.include?(type)
        record = ActivityEvent.create!(site: site, actor_id: actor&.persisted? ? actor.id : nil,
          actor_name: actor&.username || "system", category: category, action: action, outcome: outcome,
          subject_type: type, subject_id: subject&.id, subject_owner_id: owner_id, details: safe)
        prune!(site)
        record
      end
    rescue ActiveRecord::ActiveRecordError => error
      Rails.logger.error("Activity journal write unavailable (#{error.class.name})")
      raise Unavailable, "Activity journal is unavailable; no business change was saved", cause: nil
    end
    def try_record!(**attributes)
      record!(**attributes)
    rescue Unavailable
      false
    end
    def prune!(site)
      ActivityEvent.where(site: site).where("created_at < ?", RETENTION.ago).order(:id).limit(100).pluck(:id).then do |ids|
        ActivityEvent.where(id: ids).delete_all if ids.any?
      end
      ids = ActivityEvent.where(site: site).order(id: :desc).offset(LIMIT).limit(100).pluck(:id)
      ActivityEvent.where(id: ids).delete_all if ids.any?
    end
    def scope_for(actor)
      Identity::Capabilities.require!(actor, :view_activity)
      scope = ActivityEvent.where(site: Site.find_by!(singleton_key: 1)).where("created_at >= ?", RETENTION.ago)
      return scope if actor.owner?
      categories = actor.administrator? ? %w[editorial media navigation] : %w[editorial media]
      domain = scope.where(category: categories)
      return domain if actor.administrator? || actor.editor?
      domain.where("actor_id = ? OR subject_owner_id = ?", actor.id, actor.id)
        .or(scope.where(category: "security", actor_id: actor.id))
    end
  end
end
