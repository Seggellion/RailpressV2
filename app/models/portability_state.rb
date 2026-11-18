class PortabilityState < ApplicationRecord
  belongs_to :site
  belongs_to :active_import, class_name: "ImportBatch", optional: true
  before_validation { self.public_id ||= SecureRandom.uuid }
end
