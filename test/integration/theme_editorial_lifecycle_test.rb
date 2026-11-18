require_relative "seo_lifecycle_test"
require_relative "../support/theme_test_support"
# Execute the complete established SEO lifecycle again through an installed theme.
class ThemeEditorialLifecycleTest < SeoLifecycleTest
  include ThemeTestSupport
  setup { activate(stage) }
  def seo_evidence_prefix = "#{ENV.fetch('RAILPRESS_TEST_ENGINE')}-theme"
end
