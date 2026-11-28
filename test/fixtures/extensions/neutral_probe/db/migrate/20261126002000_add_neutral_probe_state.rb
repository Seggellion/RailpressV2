class AddNeutralProbeState < ActiveRecord::Migration[8.1]
  def up
    add_column :rp_ext_neutral_probe_records, :status, :string
  end
end
