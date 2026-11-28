# frozen_string_literal: true

class ValidateThemeUploadJob < ApplicationJob
  def perform(upload_id)
    Themes::Uploads.perform!(upload_id)
  end
end
