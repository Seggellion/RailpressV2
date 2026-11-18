class AddRetainedMediaObjects < ActiveRecord::Migration[8.1]
  def change
    # Additive nullable expansion: old readers continue to work. GCS tombstones
    # retain immutable object bindings after existing purged/blob constraints.
    add_column :media_assets, :retained_objects, :json
  end
end
