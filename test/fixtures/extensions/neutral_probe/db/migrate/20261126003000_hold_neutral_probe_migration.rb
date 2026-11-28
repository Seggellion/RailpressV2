class HoldNeutralProbeMigration < ActiveRecord::Migration[8.1]
  def up
    add_column :rp_ext_neutral_probe_records, :recovery_probe, :string
    raise "Synthetic migration interruption"
  end
end
