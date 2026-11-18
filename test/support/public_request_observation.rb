# Capture only public eligibility SELECTs; never account/password/token SQL.
module PublicRequestObservation
  def observed_public_get(path, **options)
    @qualification_request_trace = { before: { realtime: Time.now.utc.iso8601(6), monotonic: Process.clock_gettime(Process::CLOCK_MONOTONIC) }, eligibility_queries: [] }
    callback = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql]
      next unless sql.match?(/SELECT.*FROM [\x22\x60]contents[\x22\x60]/im) && sql.include?("published_at") && sql.match?(/<=/)
      values = payload[:type_casted_binds]
      values = values.call if values.respond_to?(:call)
      @qualification_request_trace[:eligibility_queries] << { sql: sql, cached: !!payload[:cached], binds: Array(values).map { |value| value.respond_to?(:iso8601) ? value.iso8601(6) : value } }
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { get(path, **options) }
  ensure
    if @qualification_request_trace
      @qualification_request_trace[:after] = { realtime: Time.now.utc.iso8601(6), monotonic: Process.clock_gettime(Process::CLOCK_MONOTONIC), status: response.status }
    end
  end
end
