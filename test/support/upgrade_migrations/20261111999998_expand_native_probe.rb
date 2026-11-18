class ExpandNativeProbe < ActiveRecord::Migration[8.1]
  def change
    add_column :platform_states, :qualification_note, :string
  end
end
