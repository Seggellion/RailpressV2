module OfficialNewsTestSupport
  def news_post(title = "Reviewed public Post")
    post=Editorial::Workflow.create!(actor: @owner, kind: "Post", attributes: { "title"=>title, "slug"=>Railpress::ContentRoutes.slug(title), "excerpt"=>"Short public excerpt.", "body"=>"<p>PRIVATE BODY IS NOT NEWS METADATA</p>", "visibility"=>"public" })
    Editorial::Workflow.update!(actor: @owner, content: post, expected_version: post.lock_version, event: "publish")
    post
  end
  def provider_site
    Site.first.update!(canonical_origin: OfficialNews::Schema::ORIGIN, indexing_enabled: true)
    OfficialNews::Controls.call(actor: @owner, operation: "provider_enable", version: 0)
  end
  def review(post)
    OfficialNews::Provider.review!(actor: @owner, content_id: post.id, expected_version: post.lock_version)
  end
  def news_payload
    { "schema_version"=>1, "items"=>[ { "id"=>"12345678-1234-4234-8234-123456789abc", "title"=>"Original product update", "excerpt"=>"A safe public summary.", "url"=>"https://railpress.org/blog/product-update", "published_at"=>"2026-11-13T00:00:00Z", "modified_at"=>"2026-11-13T00:00:00Z" } ] }
  end
  class NewsClientDouble
    attr_reader :calls, :headers
    attr_accessor :failure, :status, :payload, :hook
    def initialize(payload)
      @payload=payload;@calls=0;@status=200;@headers=[]
    end
    def get(**headers)
      @calls+=1;@headers<<headers
      hook&.call
      raise OfficialNews::Client::Failure, failure if failure
      OfficialNews::Client::Response.new(status: status, payload: payload, etag: '"synthetic-safe-etag"', last_modified: "Fri, 13 Nov 2026 00:00:00 GMT")
    end
  end
end
