module NeutralProbe
  class RecordJob < ::ApplicationJob
    queue_as :neutral_probe

    def perform
      return false unless ::Extensions::Activation.enabled?("neutral-probe")

      ActiveRecord::Base.connection.execute("INSERT INTO rp_ext_neutral_probe_records (value) VALUES ('neutral-probe')")
      true
    end
  end
end
