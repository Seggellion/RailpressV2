require "test_helper"
require_relative "../support/security_clock_test_support"
require_relative "../support/installation_test_support"

class ClockInstallationTest < ActionDispatch::IntegrationTest
  include InstallationTestSupport
  include SecurityClockTestSupport

  [ 1, 2, 3, 5 ].each do |seconds|
    test "installation commits once when menu validation observes a #{seconds} second rollback" do
      csrf = review_install
      original = Navigation::Tree.method(:validate!)
      test_clock = self
      replacement = lambda do |rows, retained: []|
        test_clock.travel(-seconds.seconds) { original.call(rows, retained: retained) }
      end
      replacing_method(Navigation::Tree, :validate!, replacement) do
        post "/setup/complete", params: finish_params(csrf)
      end
      assert_response :see_other
      assert @state.installed?
      assert_equal 1, User.where(role: "owner").count
      assert_equal 1, Site.count
      assert_equal 3, MenuLocation.where.not(published_menu_id: nil).count
      assert_equal 3, Page.publicly_visible.count
      get "/setup"; assert_response :gone
    end
  end

  test "observed forward secret and claim expiry cannot revive after rollback" do
    secret = @state.issue!
    travel(31.minutes) { assert_raises(Railpress::BootstrapState::InvalidClaim) { @state.claim!(secret) } }
    assert_raises(Railpress::BootstrapState::InvalidClaim) { @state.claim!(secret) }
    fresh = @state.issue!
    claim = @state.claim!(fresh)
    travel(11.minutes) { refute @state.claimed?(claim) }
    refute @state.claimed?(claim)
    assert_raises(Railpress::BootstrapState::InvalidClaim) { @state.with_claim!(claim) { flunk "expired claim" } }
  end
  test "a backward step during secret and claim binding preserves one captured absolute expiry" do
    original_deadline = @state.method(:clock_deadline)
    test_clock = self
    replacement = lambda do |*args|
      test_clock.travel(-3.seconds) { original_deadline.call(*args) }
    end
    replacing_method(@state, :clock_deadline, replacement) do
      secret = @state.issue!
      claim = @state.claim!(secret)
      assert @state.claimed?(claim)
    end
  end
end
