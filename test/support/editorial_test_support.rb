module EditorialTestSupport
  extend ActiveSupport::Concern
  include IdentityTestSupport
  included do
    setup do
      install_site!
      @author = create_account("author")
      @editor = create_account("editor")
    end
  end
  def draft(kind = "Post", actor: @author, **attributes)
    Editorial::Workflow.create!(actor: actor, kind: kind, attributes: {
      "title" => "Café publishing 日本語", "slug" => "cafe-publishing", "body" => "<h2>Welcome</h2><p>Hello <strong>world</strong> — 日本語.</p>",
      "excerpt" => "A real summary", "visibility" => "public", "template_key" => "standard"
    }.merge(attributes.transform_keys(&:to_s)))
  end
  def change(content, event = "save", actor: @editor, attributes: {}, version: content.lock_version, revision: nil)
    Editorial::Workflow.update!(actor: actor, content: content, expected_version: version,
      attributes: attributes.transform_keys(&:to_s), event: event, revision_id: revision)
  end
  def term(kind = "category", name = "News")
    Editorial::Terms.create!(actor: @editor, kind: kind, name: name, slug: name)
  end
end
