class ImportItem < ApplicationRecord
  attribute :details, default: -> { {} }
  belongs_to :import_batch
  validates :kind, inclusion: { in: %w[author term media content revision menu redirect settings appearance] }
  validates :state, inclusion: { in: %w[planned processing staged matched activated reversed] }
end
