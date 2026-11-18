# frozen_string_literal: true

module Railpress
  module Harness
    module Templates
      module_function

      def files(feature)
        constant = feature.split("_").map(&:capitalize).join
        helper = if feature == "reading_time"
          <<~RUBY
            def minutes(text, words_per_minute: 200)
              raise ArgumentError, "plain UTF-8 text required" unless text.is_a?(String) && text.encoding == Encoding::UTF_8 && text.valid_encoding? && text.bytesize <= 1_048_576
              raise ArgumentError, "reading rate must be an integer from 1 to 1000" unless words_per_minute.is_a?(Integer) && (1..1000).cover?(words_per_minute)
              words = text.scan(/[[:alnum:]]+(?:['’-][[:alnum:]]+)*/u).size
              (words + words_per_minute - 1) / words_per_minute
            end
          RUBY
        else
          "# Implement the reviewed feature here; keep authoritative services in charge.\n"
        end
        checks = if feature == "reading_time"
          <<~RUBY
            test "plain prose counts rounded reading minutes including Unicode" do
              assert_equal 0, Railpress::Extensions::ReadingTime.minutes("")
              assert_equal 1, Railpress::Extensions::ReadingTime.minutes("Café déjà vu — hello!")
              assert_equal 1, Railpress::Extensions::ReadingTime.minutes(([ "word" ] * 200).join(" "))
              assert_equal 2, Railpress::Extensions::ReadingTime.minutes(([ "word" ] * 201).join(" "))
              assert_equal 3, Railpress::Extensions::ReadingTime.minutes(([ "word" ] * 401).join(" "))
              assert_equal 2, Railpress::Extensions::ReadingTime.minutes("one two three", words_per_minute: 2)
            end
            test "invalid reading inputs fail without changing application policy" do
              [ 0, -1, 1.5, nil, 1001 ].each { |rate| assert_raises(ArgumentError) { Railpress::Extensions::ReadingTime.minutes("text", words_per_minute: rate) } }
              [ nil, "a" * 1_048_577, "\\xff".force_encoding("UTF-8") ].each { |text| assert_raises(ArgumentError) { Railpress::Extensions::ReadingTime.minutes(text) } }
            end
          RUBY
        else
          "test(\"reviewed feature acceptance\") { flunk \"Implement the reviewed acceptance scenarios before integration\" }\n"
        end
        {
          "lib/railpress/extensions/#{feature}.rb" => "# frozen_string_literal: true\n\nmodule Railpress\n  module Extensions\n    module #{constant}\n      module_function\n#{helper.lines.map { |line| '      ' + line }.join}    end\n  end\nend\n",
          "app/controllers/harness_extensions/#{feature}_controller.rb" => "# Unmounted development skeleton. Review capabilities, routing, SEO and privacy before integration.\nmodule HarnessExtensions\n  class #{constant}Controller < ApplicationController\n    def show\n      head :not_found\n    end\n  end\nend\n",
          "app/views/harness_extensions/#{feature}/show.html.erb" => "<section aria-label=\"Feature development\"><p>This feature has no public route.</p></section>\n",
          "docs/harness/route_proposals/#{feature}.rb" => "# REVIEW ONLY; this file is never loaded by Rails.\n# Proposed integration must be reviewed against Seo::RouteRegistry, publication\n# policy, protected routes and capabilities. No route or permission is granted.\n# Rails.application.routes.draw do\n#   get \"/reviewed-feature-path\", to: \"harness_extensions/#{feature}#show\"\n# end\n",
          "test/harness_extensions/#{feature}_test.rb" => "require \"test_helper\"\nrequire Rails.root.join(\"lib/railpress/extensions/#{feature}\")\n\nclass #{constant}ExtensionTest < ActiveSupport::TestCase\n#{checks.lines.map { |line| '  ' + line }.join}end\n"
        }
      end
    end
  end
end
