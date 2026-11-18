# frozen_string_literal: true

require "railpress/releases"
module Releases
  module Catalog
    SCOPE = "release_updates"
    FRESH = 6.hours.to_i
    RETAIN = 30.days.to_i
    module_function
    def row(key) = PlatformState.find_by(scope_name: SCOPE, key_name: key)
    def payload(key) = PlatformState.uncached { row(key)&.payload } || {}
    def save!(key, value)
      record = PlatformState.find_or_initialize_by(scope_name: SCOPE, key_name: key)
      record.update!(payload: value)
    end
    def settings = payload("settings").reverse_merge("enabled" => false, "channel" => Railpress::Product::CHANNEL, "generation" => 0)
    def binding(clock, ttl) = clock.issue(ttl: ttl, expires_at: Time.now + ttl)
    def valid?(clock, value, ttl)
      value.is_a?(Hash) && value["wall_deadline"].is_a?(Numeric) && clock.valid?(value, expires_at: Time.at(value["wall_deadline"]), ttl: ttl)
    end
    def configure!(actor:, enabled:, channel:)
      raise ArgumentError, "release_channel" unless %w[alpha stable].include?(channel)
      Site.transaction do
        Site.find_by!(singleton_key: 1).lock!; actor.lock!
        Identity::Capabilities.require!(actor, :inspect_updates)
        current = settings
        save!("settings", current.merge("enabled" => enabled == true, "channel" => channel, "generation" => current["generation"] + 1))
        save!("catalog", {}) unless enabled
        Activity::Recorder.record!(actor: actor, action: "release.checks", details: { operation: enabled ? "enable" : "disable" })
      end
      ReleaseCheckJob.perform_later if enabled
    end
    def refresh!(source: GithubSource.new, clock: Railpress::SecurityClock.for_application)
      lease = SecureRandom.uuid
      generation = Site.transaction do
        Site.find_by!(singleton_key: 1).lock!
        config = settings; cache = payload("catalog")
        next unless config["enabled"] && !clock.sample["anomaly"]
        next if (cache["generation"] == config["generation"] && valid?(clock, cache["next_check"], cache.fetch("next_check_ttl", FRESH))) || valid?(clock, cache["lease_binding"], 30)
        save!("catalog", cache.merge("generation" => config["generation"], "lease" => lease, "lease_binding" => binding(clock, 30)))
        config["generation"]
      end
      return unless generation
      # Bounded metadata only. Packages are fetched solely by a trusted operator.
      candidates = Timeout.timeout(15) { source.releases.map { |candidate| source.metadata(candidate) } }
      Site.transaction do
        Site.find_by!(singleton_key: 1).lock!
        cache = payload("catalog"); config = settings
        next unless config["enabled"] && config["generation"] == generation && cache["lease"] == lease
        policy = Requests.roots
        security = payload("trust").reverse_merge("trust_generation" => 0, "revoked" => [], "utc_max" => 0, "sequences" => {})
        policy.apply!(security)
        accepted = candidates.filter_map do |candidate|
          manifest = Railpress::Releases::Manifest.validate!(candidate.fetch("manifest"))
          policy.verify!(Railpress::Releases.canonical(manifest), candidate.fetch("signature"), security, purpose: "release")
          raise ArgumentError, "release_tag_version" unless manifest["version"] == candidate["version"]
          expected_url = "https://github.com/#{GithubSource::REPOSITORY}/releases/download/v#{manifest['version']}/package.tar.gz"
          raise ArgumentError, "release_package_url" unless candidate["package_url"] == expected_url
          next unless manifest["channel"] == config["channel"] || (config["channel"] == "alpha" && manifest["channel"] == "stable")
          id = Digest::SHA256.hexdigest(Railpress::Releases.canonical(manifest))
          { "release_id" => id, **candidate }
        end
        # Check a channel's newest sequence only after the bounded list is parsed;
        # older published records remain historical, never replay authority.
        accepted.group_by { |item| item["manifest"]["channel"] }.each do |channel, items|
          raise ArgumentError, "metadata_sequence_collision" if items.group_by { |item| item["manifest"]["sequence"] }.values.any? { |group| group.map { |item| item["release_id"] }.uniq.length > 1 }
          newest = items.max_by { |item| item["manifest"]["sequence"] }
          prior = security["sequences"][channel]
          seq = newest["manifest"]["sequence"]
          raise ArgumentError, "metadata_replay" if prior && (seq < prior["sequence"] || (seq == prior["sequence"] && newest["release_id"] != prior["release_id"]))
          security["sequences"][channel] = { "sequence" => seq, "release_id" => newest["release_id"] }
        end
        save!("trust", security)
        save!("catalog", { "items" => accepted, "generation" => generation, "fresh" => binding(clock, FRESH),
          "retention" => binding(clock, RETAIN), "next_check" => binding(clock, FRESH), "next_check_ttl" => FRESH, "error" => nil })
      end
    rescue StandardError
      Site.transaction do
        Site.find_by!(singleton_key: 1).lock!
        cache = payload("catalog")
        save!("catalog", cache.merge("error" => "release_check_unavailable", "lease" => nil, "lease_binding" => nil,
          "next_check" => binding(clock, 300), "next_check_ttl" => 300)) if cache["lease"] == lease
      end
      nil
    end
    def verified_items
      cache = payload("catalog")
      config = settings
      return [] unless config["enabled"] && valid?(Railpress::SecurityClock.for_application, cache["retention"], RETAIN)
      policy = Requests.roots; security = payload("trust")
      policy.apply!(security)
      Array(cache["items"]).first(5).select do |item|
        manifest = Railpress::Releases::Manifest.validate!(item.fetch("manifest"))
        policy.verify!(Railpress::Releases.canonical(manifest), item.fetch("signature"), security, purpose: "release")
        base = "https://github.com/#{GithubSource::REPOSITORY}/releases/download/v#{manifest['version']}"
        allowed_channel = manifest["channel"] == config["channel"] || (config["channel"] == "alpha" && manifest["channel"] == "stable")
        highest = security.fetch("sequences", {})[manifest["channel"]]
        unreplayed = !highest || manifest["sequence"] > highest["sequence"] || (manifest["sequence"] == highest["sequence"] && item["release_id"] == highest["release_id"])
        allowed_channel && unreplayed && item["release_id"] == Digest::SHA256.hexdigest(Railpress::Releases.canonical(manifest)) &&
          item["version"] == manifest["version"] && item["package_url"] == "#{base}/package.tar.gz" && item["plan_url"] == "#{base}/native-plan.json"
      end
    rescue StandardError
      []
    end
    def view
      config = settings; cache = payload("catalog")
      return { "state" => "DISABLED", "notice" => "Public release checks are off.", "candidate" => nil, "items" => [] } unless config["enabled"]
      items = verified_items
      items = items.select { |item| Railpress::Releases.compare_versions(item["version"], Railpress::Product::VERSION).positive? }
      candidate = items.max { |a, b| Railpress::Releases.compare_versions(a["version"], b["version"]) }
      compatible = false
      if candidate
        begin
          Railpress::Releases::Manifest.compatible!(candidate["manifest"], Context.current); compatible = true
        rescue Railpress::Releases::Invalid
          compatible = false
        end
      end
      fresh = !cache["error"] && valid?(Railpress::SecurityClock.for_application, cache["fresh"], FRESH)
      { "state" => fresh ? "FRESH" : "STALE / UNKNOWN", "candidate" => candidate, "items" => items, "compatible" => compatible,
        "notice" => candidate ? (compatible ? "Railpress update available" : "Update requires compatibility review") :
          (fresh ? (Array(cache["items"]).any? ? "Already up to date for the checked channel" : "No signed update is available in the bounded release listing") : "Release availability is unknown; local publishing remains available."),
        "detail" => "Cached signed metadata only. Fresh trusted UTC, package verification, host and backup approval remain operator gates." }
    rescue StandardError
      { "state" => "UNKNOWN", "notice" => "Release evidence unavailable; local publishing remains available.", "candidate" => nil, "items" => [] }
    end
  end
end
