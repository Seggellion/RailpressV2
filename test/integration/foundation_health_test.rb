require "test_helper"

class FoundationHealthTest < ActionDispatch::IntegrationTest
  test "core health returns OK without active theme mutation" do
    before = Rails.application.config.respond_to?(:active_theme) ? Rails.application.config.active_theme : nil
    get "/up"
    assert_response :success
    assert_nil before
    assert_nil(Rails.application.config.respond_to?(:active_theme) ? Rails.application.config.active_theme : nil)
  end
end
