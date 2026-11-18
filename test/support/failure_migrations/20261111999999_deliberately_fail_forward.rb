class DeliberatelyFailForward < ActiveRecord::Migration[8.1]
  def change
    create_table :m01_failure_probe do |t|
      t.string :value
    end
    execute "THIS IS DELIBERATELY INVALID SQL"
  end
end
