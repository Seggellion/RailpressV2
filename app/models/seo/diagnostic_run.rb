module Seo
  class DiagnosticRun < ApplicationRecord
    self.table_name = "seo_diagnostic_runs"
    belongs_to :requester, class_name: "User"
    has_many :diagnostic_targets, class_name: "Seo::DiagnosticTarget", foreign_key: :seo_diagnostic_run_id, dependent: :delete_all
    validates :status, inclusion: { in: %w[pending running completed failed cancelled] }
    validates :mode, inclusion: { in: %w[offline http] }
    validates :summary, presence: true
    def finish!(status, summary)
      update!(status: status, active_key: nil, finished_at: Time.current, summary: summary)
    end
  end
end
