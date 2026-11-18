module OfficialNews
  module Controls
    class Conflict < StandardError; end
    OPERATIONS=%w[enable disable clear refresh provider_enable provider_disable].freeze
    module_function
    def call(actor:, operation:, version:)
      raise ArgumentError, "Unknown news action." unless OPERATIONS.include?(operation)
      state=Site.transaction do
        site=Site.lock.find_by!(singleton_key: 1)
        fresh=User.lock.find(actor.id)
        Identity::Capabilities.require!(fresh, :manage_identity)
        raise Identity::Capabilities::Denied unless fresh.auth_version==actor.auth_version
        row=OfficialNewsState.find_or_create_by!(site: site)
        row.lock!
        raise Conflict, "News settings changed. Reload before trying again." unless row.lock_version.to_s==version.to_s
        raise ArgumentError, "The official provider requires the configured Railpress.org canonical origin." if operation=="provider_enable" && site.canonical_origin!=Schema::ORIGIN
        row.generation+=1
        row.lease_key=nil;row.lease_binding=nil;row.wait_binding=nil
        case operation
        when "enable" then row.enabled=true
        when "disable"
          row.enabled=false
          clear!(row)
        when "clear" then clear!(row)
        when "provider_enable" then row.provider_enabled=true
        when "provider_disable"
          row.provider_enabled=false
          clear!(row) if site.canonical_origin==Schema::ORIGIN
        when "refresh"
          raise ArgumentError, "Enable official news before requesting a refresh." unless row.enabled
        end
        row.save!
        Activity::Recorder.record!(actor: fresh, action: "news.#{operation}", details: { operation: operation })
        row
      end
      queued_generation=state.generation
      if state.enabled && %w[enable refresh clear].include?(operation)
        begin
          OfficialNewsRefreshJob.perform_later(state.id, state.generation)
        rescue StandardError
          state.with_lock { state.update!(last_error: "queue_unavailable") if state.generation==queued_generation && state.enabled }
        end
      end
      state
    end
    def clear!(row)
      %w[payload etag last_modified retrieved_at fresh_binding retention_binding].each { |key|row[key]=nil }
      row.failures=0;row.last_error=nil
    end
  end
end
