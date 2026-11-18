module Seo
  class DiagnosticTarget < ApplicationRecord
    self.table_name = "seo_diagnostic_targets"
    belongs_to :diagnostic_run, class_name: "Seo::DiagnosticRun", foreign_key: :seo_diagnostic_run_id
    attr_readonly :url, :url_digest, :family, :position, :seo_diagnostic_run_id
    before_validation -> { self.url_digest = Digest::SHA256.hexdigest(url.to_s) }, if: :new_record?
    validates :url, presence: true, length: { maximum: 2048 }
    validates :family, inclusion: { in: %w[page post blog category tag] }
    validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  end
end
