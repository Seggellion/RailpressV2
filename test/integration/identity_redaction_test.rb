require "test_helper"
require "stringio"
require_relative "../support/installation_test_support"

class IdentityRedactionTest < ActionDispatch::IntegrationTest
  include InstallationTestSupport

  test "setup passwords and reset tokens do not enter controller SQL or mail logs" do
    assert_nil ActionMailer::Base.logger
    buffer = StringIO.new
    logger = ActiveSupport::Logger.new(buffer)
    logger.level = Logger::DEBUG
    old_controller = ActionController::Base.logger
    old_record = ActiveRecord::Base.logger
    ActionController::Base.logger = logger
    ActiveRecord::Base.logger = logger
    secret = @state.issue!
    csrf = csrf_token_for(self, "/setup")
    post "/setup/claim", params: { setup_secret: secret, authenticity_token: csrf }
    prepare_install_schema
    Installation::Progress::STEPS[0...-1].each { |step| advance_install(self, step) }
    csrf = csrf_token_for(self, "/setup")
    post "/setup/complete", params: finish_params(csrf)
    assert_response :see_other
    @owner = User.find_by!(role: "owner")
    sign_in
    token = create_recovery_token
    csrf = csrf_token_for(self, "/password/reset")
    patch "/password/reset", params: { recovery_token: token, password: "redacted-replacement-password!", password_confirmation: "redacted-replacement-password!", authenticity_token: csrf }
    assert_response :see_other
    output = buffer.string
    [ secret, PASSWORD, token, "redacted-replacement-password!" ].each { |value| refute_includes output, value }
    assert_includes output, "FILTERED"
  ensure
    ActionController::Base.logger = old_controller if old_controller
    ActiveRecord::Base.logger = old_record if old_record
  end
end
