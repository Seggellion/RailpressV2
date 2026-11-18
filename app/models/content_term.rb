class ContentTerm < ApplicationRecord
  belongs_to :content
  belongs_to :term
  validates :stage, inclusion: { in: %w[draft live] }
end
