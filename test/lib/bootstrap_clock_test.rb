require "test_helper"

class BootstrapClockTest < ActiveSupport::TestCase
  include IdentityTestSupport

  def controlled_state
    Class.new(Railpress::BootstrapState) do
      attr_accessor :ticks, :boot
      private
      def monotonic = ticks
      def boot_identity = boot
    end.new(@private_root).tap { |state| state.ticks = 100.0; state.boot = "synthetic-boot" }
  end

  test "a backward wall clock cannot extend the monotonic secret or claim lifetime" do
    state = controlled_state
    secret = state.issue!
    state.ticks += 1801
    travel(-1.hour) { assert_raises(Railpress::BootstrapState::InvalidClaim) { state.claim!(secret) } }
    secret = state.issue!
    claim = state.claim!(secret)
    state.ticks += 601
    travel(-1.hour) { refute state.claimed?(claim) }
  end

  test "process replacement on the same boot retains the fence while another boot invalidates it" do
    state = controlled_state
    claim = state.claim!(state.issue!)
    replacement = controlled_state
    assert replacement.claimed?(claim)
    replacement.boot = "another-synthetic-boot"
    refute replacement.claimed?(claim)
  end
end
