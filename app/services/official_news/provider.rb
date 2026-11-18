module OfficialNews
  module Provider
    module_function
    def digest(content)
      Digest::SHA256.hexdigest(Railpress::Releases.canonical({ "snapshot"=>content.published_snapshot,
        "published_at"=>content.published_at&.iso8601(6), "modified_at"=>content.public_updated_at&.iso8601(6) }))
    end
    def review!(actor:, content_id:, expected_version:)
      Site.transaction do
        site = Site.lock.find_by!(singleton_key: 1)
        fresh = User.lock.find(actor.id)
        Identity::Capabilities.require!(fresh, :manage_identity)
        raise Identity::Capabilities::Denied unless fresh.auth_version == actor.auth_version
        post = Post.lock.find(content_id)
        raise Editorial::Workflow::Conflict, "Publication changed. Reload and review its current public version." unless expected_version.to_s == post.lock_version.to_s
        raise Schema::Invalid, "publication_not_eligible" unless eligible?(site, post)
        review = OfficialNewsReview.find_or_initialize_by(content: post)
        review.public_id ||= SecureRandom.uuid
        revision=post.content_revisions.where(event: %w[publish scheduled_publish]).maximum(:id)
        raise Schema::Invalid, "publication_not_eligible" unless revision
        review.update!(actor: fresh, publication_digest: digest(post), publication_revision_id: revision)
        Activity::Recorder.record!(actor: fresh, action: "news.reviewed", subject: post, owner_id: post.author_id, details: { revision: post.lock_version })
        review
      end
    end
    def eligible?(site, post)
      Seo::Policy.visible?(post) && Seo::Policy.decision(site: site, family: :post).indexable? &&
        site.canonical_origin == Schema::ORIGIN
    end
    def text(value, max)
      Editorial::RichText.clean(value.to_s).then { |html| Rails::Html::FullSanitizer.new.sanitize(html) }.to_s.gsub(/[<>\x00-\x1f\x7f]/, " ").squish.first(max)
    end
    def call(site:)
      state = OfficialNewsState.find_by(site: site)
      raise Schema::Invalid, "provider_disabled" unless state&.provider_enabled && site.canonical_origin == Schema::ORIGIN
      rows = Post.publicly_visible.joins("INNER JOIN official_news_reviews ON official_news_reviews.content_id=contents.id")
        .where("official_news_reviews.publication_revision_id = (SELECT MAX(publication.id) FROM content_revisions publication WHERE publication.content_id=contents.id AND publication.event IN ('publish','scheduled_publish'))")
        .select("contents.*, official_news_reviews.public_id AS news_public_id, official_news_reviews.publication_digest AS news_review_digest")
        .order(id: :desc).limit(Schema::MAX_ITEMS)
      items=rows.filter_map do |post|
        next unless eligible?(site, post) && post.news_review_digest==digest(post)
        policy=Seo::Policy.new(site: site, family: :post, path: Railpress::ContentRoutes.path("Post", post.published_snapshot.fetch("slug")), content: post)
        title=text(post.published_snapshot["title"], 200)
        excerpt=text(post.published_snapshot["excerpt"].presence || post.published_snapshot["title"], 500)
        { "id"=>post.news_public_id, "title"=>title, "excerpt"=>excerpt, "url"=>policy.canonical,
          "published_at"=>post.first_published_at.iso8601(6), "modified_at"=>post.public_updated_at.iso8601(6) }
      end
      Schema.normalize({ "schema_version"=>1, "items"=>items })
    end
  end
end
