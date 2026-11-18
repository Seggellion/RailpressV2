module OfficialNews
  module Cache
    FRESH = 6.hours.to_i
    RETAIN = 30.days.to_i
    module_function
    def binding(clock, ttl)
      clock.issue(ttl: ttl, expires_at: Time.now+ttl)
    end
    def valid?(clock, value, ttl)
      value.is_a?(Hash) && value["wall_deadline"].is_a?(Numeric) &&
        clock.valid?(value, expires_at: Time.at(value["wall_deadline"]), ttl: ttl)
    end
    def view(state, clock: Railpress::SecurityClock.for_application)
      return { "state"=>"DISABLED", "items"=>[], "detail"=>"Official news is off. No requests are scheduled." } unless state&.enabled || state&.provider_enabled
      if state.provider_enabled && state.site.canonical_origin==Schema::ORIGIN
        return { "state"=>"LOCAL", "items"=>Provider.call(site: state.site)["items"], "detail"=>"Reviewed official Posts are read locally; no HTTP request." }
      end
      if state.site.canonical_origin==Schema::ORIGIN
        return { "state"=>"OFFLINE", "items"=>[], "detail"=>"The local official provider is disabled; no HTTP self-request is made." }
      end
      payload=state.payload && Schema.normalize(state.payload)
      retained=payload && state.retrieved_at && valid?(clock, state.retention_binding, RETAIN)
      return { "state"=>state.last_error ? "OFFLINE" : "UNKNOWN", "items"=>[], "detail"=>"No usable local news cache. Site publishing works independently." } unless retained
      observation=clock.sample
      fresh=!observation["anomaly"] && valid?(clock, state.fresh_binding, FRESH)
      { "state"=>fresh ? (state.last_error ? "DEGRADED" : "FRESH") : "STALE", "items"=>payload["items"], "retrieved_at"=>state.retrieved_at,
        "detail"=>fresh ? "Public metadata from the last successful background refresh." : "Last-known public metadata. Provider freshness is unconfirmed.",
        "last_error"=>state.last_error }
    rescue StandardError
      { "state"=>"UNKNOWN", "items"=>[], "detail"=>"News evidence is unavailable. Local publishing remains available." }
    end
  end
end
