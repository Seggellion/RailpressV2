require "time"
module OfficialNews
  module Schema
    ORIGIN = "https://railpress.org".freeze
    ENDPOINT = "#{ORIGIN}/api/public/v1/news.json".freeze
    MAX_BYTES = 256 * 1024
    MAX_ITEMS = 20
    class Invalid < StandardError; end
    module_function
    def plain(value, max:)
      raise Invalid, "invalid_text" unless value.is_a?(String) && value.valid_encoding? && value.length.between?(1, max) && !value.strip.empty? && !value.match?(/[<>\x00-\x1f\x7f]/)
      value
    end
    def url(value)
      raise Invalid, "invalid_url" unless value.is_a?(String) && value.ascii_only? && value.bytesize <= 2048
      uri = URI.parse(value)
      raise Invalid, "invalid_url" unless uri.is_a?(URI::HTTPS) && uri.host == "railpress.org" && uri.port == 443 && !uri.userinfo && !uri.query && !uri.fragment && uri.path.match?(%r{\A/blog/[a-z0-9]+(?:-[a-z0-9]+)*\z}) && value == "#{ORIGIN}#{uri.path}"
      value
    rescue URI::InvalidURIError
      raise Invalid, "invalid_url"
    end
    def date(value)
      raise Invalid, "invalid_date" unless value.is_a?(String) && value.match?(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?Z\z/)
      parsed=Time.iso8601(value)
      raise Invalid, "invalid_date" unless parsed.utc.iso8601.first(19)==value.first(19)
      value
    rescue ArgumentError
      raise Invalid, "invalid_date"
    end
    def normalize(value)
      raise Invalid, "invalid_schema" unless value.is_a?(Hash) && value.keys.sort == %w[items schema_version] && value["schema_version"] == 1 && value["items"].is_a?(Array) && value["items"].length <= MAX_ITEMS
      seen = []
      items = value["items"].map do |row|
        raise Invalid, "invalid_item" unless row.is_a?(Hash) && row.keys.sort == %w[excerpt id modified_at published_at title url]
        id = row["id"]
        raise Invalid, "invalid_identity" unless id.is_a?(String) && id.match?(/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/) && !seen.include?(id)
        seen << id
        { "id"=>id, "title"=>plain(row["title"], max: 200), "excerpt"=>plain(row["excerpt"], max: 500),
          "url"=>url(row["url"]), "published_at"=>date(row["published_at"]), "modified_at"=>date(row["modified_at"]) }
      end
      result = { "schema_version"=>1, "items"=>items }
      raise Invalid, "oversized_feed" if JSON.generate(result).bytesize > MAX_BYTES
      result
    end
    def parse(bytes)
      raise Invalid, "oversized_feed" unless bytes.is_a?(String) && bytes.bytesize <= MAX_BYTES
      normalize(JSON.parse(bytes, max_nesting: 8))
    rescue JSON::ParserError, JSON::NestingError
      raise Invalid, "invalid_json"
    end
  end
end
