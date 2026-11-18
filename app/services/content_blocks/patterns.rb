module ContentBlocks
  module Patterns
    module_function
    def fetch(key)
      blocks = case key
      when "small_business"
        [ { "type" => "hero", "heading" => "A thoughtful service for your community", "text" => "Replace this introduction with your own story.", "label" => "Explore our services", "url" => "/services" },
          { "type" => "features", "items" => [ { "heading" => "What we do", "text" => "Explain a useful service and who it helps." } ] },
          { "type" => "testimonial", "quote" => "Add an authentic quotation only with permission.", "attribution" => "Attribution" } ]
      when "about"
        [ { "type" => "heading", "text" => "The people behind the work", "level" => 2 },
          { "type" => "paragraph", "html" => "<p>Tell your story, your approach and what people can expect when they work with you.</p>" } ]
      when "services"
        [ { "type" => "heading", "text" => "How we can help", "level" => 2 },
          { "type" => "features", "items" => [ { "heading" => "Your first service", "text" => "Describe the outcome and who it helps." }, { "heading" => "Your next service", "text" => "Explain the next useful step." } ] } ]
      when "testimonial"
        [ { "type" => "testimonial", "quote" => "Replace this placeholder with a real quotation, used with permission.", "attribution" => "Name and context, with permission" } ]
      when "faq"
        [ { "type" => "heading", "text" => "A few useful answers", "level" => 2 },
          { "type" => "faq", "items" => [ { "question" => "Where should I begin?", "answer" => "Explain how a visitor can take the first step." } ] } ]
      when "hero"
        [ { "type" => "hero", "heading" => "Good work starts with a conversation", "text" => "Write a clear introduction to what you do and who you help.", "label" => "", "url" => "" } ]
      when "contact_cta"
        [ { "type" => "call_to_action", "heading" => "Let's talk about your next step", "text" => "Add a public contact page link when it is ready.", "label" => "", "url" => "" } ]
      when "contact"
        [ { "type" => "heading", "text" => "Get in touch", "level" => 2 },
          { "type" => "contact", "heading" => "Contact details", "address" => "Add your public business address.", "email" => "", "phone" => "" },
          { "type" => "faq", "items" => [ { "question" => "When are you available?", "answer" => "Add your hours and response expectations." } ] } ]
      else
        raise Schema::Invalid, "Unknown starter pattern"
      end
      Schema.normalize(blocks)
    end
  end
end
