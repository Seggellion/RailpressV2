class ImportEvent < ApplicationRecord
  attribute :details, default: -> { {} }
  belongs_to :import_batch
  before_update { throw :abort }
  before_destroy { throw :abort }
end
