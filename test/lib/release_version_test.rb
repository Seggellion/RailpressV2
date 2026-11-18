require "test_helper"
require "railpress/releases"

class ReleaseVersionTest < ActiveSupport::TestCase
  test "product ordering follows SemVer including numeric prerelease identifiers and ignored build metadata" do
    order = %w[0.1.0-alpha.0 0.1.0-alpha.1 0.1.0-alpha.beta 0.1.0-beta 0.1.0-beta.2 0.1.0-beta.11 0.1.0-rc.1 0.1.0 0.2.0 1.0.0]
    order.each_cons(2) do |a, b|
      assert_operator Railpress::Releases.compare_versions(a, b), :<, 0
      assert_operator Railpress::Releases.compare_versions(b, a), :>, 0
    end
    assert_equal 0, Railpress::Releases.compare_versions("1.0.0+linux", "1.0.0+native")
    %w[01.0.0 1.0 1.0.0-01 1.0.0- 1.0.0+].each do |v|
      assert_raises(Railpress::Releases::Invalid) { Railpress::Releases.compare_versions(v, "1.0.0") }
    end
  end
end
