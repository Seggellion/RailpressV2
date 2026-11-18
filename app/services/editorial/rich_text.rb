# frozen_string_literal: true

module Editorial
  module RichText
    TAGS = %w[p br h2 h3 h4 strong em u ul ol li blockquote pre code a hr table caption thead tbody tfoot tr th td].freeze
    ATTRIBUTES = %w[href title scope].freeze
    module_function
    def clean(html)
      Rails::HTML5::SafeListSanitizer.new.sanitize(html, tags: TAGS, attributes: ATTRIBUTES)
    end
  end
end
