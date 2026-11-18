# frozen_string_literal: true

module Editorial
  module LocalTime
    class Invalid < StandardError; end
    module_function
    def parse(value, zone)
      raise Invalid, "Use a local date and time" unless /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}\z/.match?(value.to_s)
      local = DateTime.strptime(value, "%Y-%m-%dT%H:%M")
      raise Invalid, "Use a valid calendar date" unless local.strftime("%Y-%m-%dT%H:%M") == value
      civil = Time.utc(local.year, local.month, local.day, local.hour, local.min)
      timezone = TZInfo::Timezone.get(zone)
      periods = timezone.periods_for_local(civil)
      raise Invalid, "This time is missing or ambiguous at a daylight-saving transition; choose another time" unless periods.one?
      civil - periods.first.utc_total_offset
    rescue ArgumentError, TZInfo::InvalidTimezoneIdentifier
      raise Invalid, "Use a valid IANA timezone and local date/time"
    end
  end
end
