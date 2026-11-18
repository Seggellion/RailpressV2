require "timeout"
module Seo
  class SitemapCache
    Payload = Data.define(:xml, :etag, :last_modified, :count, :generated_at, :next_eligibility_at, :generated_elapsed, :clock_domain)
    def self.fetch(site:, cache: Rails.cache)
      key = [ "seo/sitemap/v3", site.install_id, site.seo_generation, site.canonical_origin, ENV["RAILPRESS_SEO_INDEXING"] ]
      payload = begin
        Timeout.timeout(0.25) { cache.read(key) }
      rescue StandardError, NotImplementedError
        Rails.logger.warn("SEO cache read unavailable; current database policy used")
        nil
      end
      clock = elapsed_clock
      if payload.is_a?(Payload) && payload.xml.is_a?(String) && payload.xml.bytesize <= 8*1024*1024 &&
          clock && payload.clock_domain == clock[1] && payload.generated_elapsed.is_a?(Numeric) &&
          payload.generated_elapsed.finite? && (clock[0] - payload.generated_elapsed).between?(0, 60)
        return payload
      end
      payload = generate(site)
      begin
        Timeout.timeout(0.25) { cache.write(key, payload, expires_in: 60.seconds) }
      rescue StandardError, NotImplementedError
        Rails.logger.warn("SEO cache write unavailable; generated sitemap retained for response")
      end
      payload
    end
    def self.elapsed_clock
      [ Railpress::SecurityClock.elapsed, Railpress::SecurityClock.boot_domain ]
    rescue Railpress::SecurityClock::Unavailable, SystemCallError, IOError, NotImplementedError
      nil # Public availability does not depend on caching or a private security journal.
    end
    def self.generate(site)
      now = Time.current
      clock = elapsed_clock
      entries = UrlInventory.call(site: site, at: now)
      xml = SitemapRenderer.new.call(entries)
      raise UrlInventory::TooLarge if xml.bytesize > 8*1024*1024
      # Scheduled publication changes the durable generation when its transition commits.
      Payload.new(xml: xml.freeze, etag: Digest::SHA256.hexdigest(xml), last_modified: site.seo_changed_at || site.updated_at, count: entries.length,
        generated_at: now.freeze, next_eligibility_at: nil, generated_elapsed: clock&.first, clock_domain: clock&.last&.freeze)
    end
  end
end
