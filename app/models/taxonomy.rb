class Taxonomy < ApplicationRecord
  has_many :terms
  validates :kind, inclusion: { in: %w[category tag] }
end
