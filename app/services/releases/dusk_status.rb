# frozen_string_literal: true

require "railpress/releases"

module Releases
  module DuskStatus
    OFFER = Railpress::Releases::DuskOffer
    class OfferConflict < StandardError; end
    module_function

    def call(site: Site.find_by!(singleton_key: 1), clock: Railpress::SecurityClock.for_application)
      installed = ThemeInstallation.where(site: site, theme_key: "dusk", status: "validated").order(:id).limit(33).to_a
      active = ThemeState.find_by(site: site)&.active_installation
      bundled = Railpress::Releases.parse(File.binread(Rails.root.join("lib/railpress/dusk.json")), limit: OFFER::LIMIT)
      result = { installed: installed.map(&:version).uniq, active: active&.theme_key == "dusk" ? active.version : nil,
        other_active: active && active.theme_key != "dusk", bundled: bundled.fetch("version") }
      return result.merge(state: "NOT_INSTALLED", notice: "Dusk is not installed on this site.") if installed.empty?
      return result.merge(state: "DISABLED", notice: "Public release checks are off.") unless Catalog.settings["enabled"]
      return result.merge(state: "UNCONFIGURED", notice: "The operator has not configured public release trust.") unless ENV["RAILPRESS_RELEASE_PUBLIC_TRUST"].present?

      cache = Catalog.payload("catalog")
      generation = Catalog.settings["generation"]
      result.merge!(last_attempt: cache["last_attempt_at"], last_success: cache["last_success_at"])
      fresh = !cache["error"] && cache["generation"] == generation && Catalog.valid?(clock, cache["fresh"], Catalog::FRESH)
      checking = Catalog.valid?(clock, cache["lease_binding"], 30) ||
        cache["manual_generation"] == generation && Catalog.valid?(clock, cache["manual_cooldown"], Catalog::RETRY)
      candidate = verified_offer(now: Time.now.to_i)
      result[:offered] = candidate if candidate
      return result.merge(state: "CHECKING", notice: "Checking for updates. Any displayed offer is from the last verified check.") if checking
      return result.merge(state: "UNKNOWN", notice: "Dusk availability is unknown. The last check failed, expired, or has not finished.") unless fresh
      return result.merge(state: "NO_VERIFIED_OFFER", notice: "No current verified Dusk offer covers this channel.") unless candidate
      if installed.length > 32 || installed.any? { |package| package.version == candidate["version"] && package.digest != candidate["digest"] }
        return result.merge(state: "CONFLICT", notice: "The installed Dusk inventory requires review before staging any update.")
      end
      installed.each { |package| Themes::Storage.load(package) }
      summarize(result, candidate, installed, active)
    rescue Railpress::ThemePackage::Invalid
      result.merge(state: "CONFLICT", notice: "An installed Dusk package failed integrity verification. Preserve it for operator review.")
    rescue OfferConflict
      result.merge(state: "CONFLICT", notice: "The verified catalog listed different package digests for the same Dusk version.")
    rescue StandardError
      { state: "UNKNOWN", notice: "Verified Dusk update information is unavailable." }
    end

    def verified_offer(now:)
      offers = Catalog.verified_items.filter_map do |item|
        manifest = item.fetch("manifest")
        next unless item["dusk_metadata"] && now >= manifest.fetch("published_at") && now < manifest.fetch("expires_at")
        OFFER.verify!(manifest, item.fetch("dusk_metadata"))
      rescue Railpress::Releases::Invalid
        nil
      end
      raise OfferConflict if offers.group_by { |value| value["version"] }.values.any? { |rows| rows.map { |row| row["digest"] }.uniq.length > 1 }
      offers.max { |a, b| Railpress::Releases.compare_versions(a["version"], b["version"]) }
    end

    def summarize(result, candidate, installed, active)
      if Railpress::Releases.compare_versions(Railpress::Product::VERSION, candidate["minimum_core"]).negative?
        return result.merge(state: "REQUIRES_CORE", notice: "This Dusk offer requires Railpress #{candidate['minimum_core']} or later.")
      end
      if candidate["theme_api"] != Railpress::Product::THEME_API
        return result.merge(state: "INCOMPATIBLE", notice: "This Dusk offer requires Theme API #{candidate['theme_api']}.")
      end

      matching = installed.find { |package| package.version == candidate["version"] && package.digest == candidate["digest"] }
      if matching && active&.id == matching.id
        return result.merge(state: "CURRENT", notice: "The verified Dusk offer is already active.")
      end
      if matching
        return result.merge(state: "STAGED", notice: "The verified Dusk package is installed. Preview it in Themes before selecting it.")
      end
      if installed.any? { |package| Railpress::Releases.compare_versions(package.version, candidate["version"]).positive? }
        return result.merge(state: "CURRENT", notice: "The verified listing offers no newer Dusk package than the one installed.")
      end
      result.merge(state: "AVAILABLE", notice: "A verified Dusk update is available. Ask the qualified native operator to stage it, then preview it in Themes.")
    end
  end
end
