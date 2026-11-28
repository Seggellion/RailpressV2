class CreateNeutralProbeRecords < ActiveRecord::Migration[8.1]
  def up
    create_table :rp_ext_neutral_probe_records do |table|
      table.string :value, null: false
    end
  end
end
