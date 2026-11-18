module OfficialNews
  class Refresh
    def initialize(clock: Railpress::SecurityClock.for_application, client: Client.new)
      @clock, @client=clock, client
    end
    def call(id, generation)
      row=OfficialNewsState.find_by(id: id)
      return unless row
      lease=SecureRandom.uuid
      claimed=row.with_lock do
        if row.payload && !Cache.valid?(@clock, row.retention_binding, Cache::RETAIN)
          Controls.clear!(row)
          row.save!
        end
        next false unless eligible?(row, generation)
        next false if Cache.valid?(@clock, row.wait_binding, Cache::FRESH) || Cache.valid?(@clock, row.lease_binding, 30)
        row.update!(lease_key: lease, lease_binding: Cache.binding(@clock, 30))
        true
      end
      return unless claimed
      row.with_lock do
        next unless eligible?(row, generation) && row.lease_key==lease
        response=if row.site.canonical_origin==Schema::ORIGIN
          Client::Response.new(status: 200, payload: Provider.call(site: row.site), etag: nil, last_modified: nil)
        else
          @client.get(etag: row.etag, last_modified: row.last_modified)
        end
        payload=response.status==304 ? (row.payload && Schema.normalize(row.payload)) : Schema.normalize(response.payload)
        raise Client::Failure, "invalid_not_modified" unless payload
        row.update!(payload: payload, etag: response.etag || row.etag, last_modified: response.last_modified || row.last_modified,
          retrieved_at: Time.current, fresh_binding: Cache.binding(@clock, Cache::FRESH),
          retention_binding: Cache.binding(@clock, Cache::RETAIN), wait_binding: Cache.binding(@clock, Cache::FRESH),
          failures: 0, last_error: nil, lease_key: nil, lease_binding: nil)
      end
    rescue StandardError=>error
      code=error.is_a?(Client::Failure) || error.is_a?(Schema::Invalid) ? error.message : "refresh_unavailable"
      code="refresh_unavailable" unless code.match?(/\A[a-z_]{1,64}\z/)
      row&.with_lock do
        next unless row.enabled && row.generation==generation && row.lease_key==lease
        failures=[ row.failures+1, 16 ].min
        row.update!(failures: failures, last_error: code, wait_binding: Cache.binding(@clock, [ 300*2**(failures-1), Cache::FRESH ].min),
          lease_key: nil, lease_binding: nil)
      end
      Rails.logger.warn("Official news refresh unavailable (#{code})")
      nil
    end
    private
    def eligible?(row, generation)
      row.enabled && row.generation==generation && !@clock.sample["anomaly"]
    end
  end
end
