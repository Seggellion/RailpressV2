class SeoDiagnosticJob < ApplicationJob
  def perform(id)
    Seo::Diagnostics.execute!(id)
  end
end
