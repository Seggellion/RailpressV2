require "set"
module Seo
  class HttpValidator
    def initialize(guard:, client: NetHttpClient.new)
      @guard, @client = guard, client
    end
    def call(url)
      current = url
      visited = Set.new
      4.times do |hop|
        raise HttpTargetGuard::UnsafeTarget, "redirect_loop" unless visited.add?(current)
        target = @guard.call(current)
        response = @client.get(uri: target.uri, ip_address: target.ip_address)
        if [ 301, 302, 303, 307, 308 ].include?(response.status)
          raise HttpTargetGuard::UnsafeTarget, "redirect_limit" if hop == 3
          raise HttpTargetGuard::UnsafeTarget, "missing_location" if response.header("location").blank?
          current = URI.join(current, response.header("location")).to_s
          next
        end
        codes = []
        codes << "redirected_inventory_url" if hop.positive?
        codes << "http_status" unless response.status == 200
        codes << "non_html_response" unless response.header("content-type").to_s.downcase.include?("html")
        document = Nokogiri::HTML(response.body) { |config| config.nonet }
        canonicals = document.css('link[rel="canonical"]')
        codes << "canonical_mismatch" unless canonicals.length == 1 && canonicals.first["href"] == url
        robots = document.css('meta[name="robots"]')
        declared = [ response.header("x-robots-tag"), *robots.map { |node| node["content"] } ].join(",").downcase
        codes << "noindex_or_missing_robots" if robots.length != 1 || declared.match?(/\bnoindex\b/) || !declared.match?(/\bindex\b/)
        graphs = document.css('script[type="application/ld+json"]').filter_map { |node| JSON.parse(node.text) rescue nil }
        codes << "structured_data_missing" unless graphs.any? { |graph| graph.is_a?(Hash) && Array(graph["@graph"]).any? { |node| node.is_a?(Hash) && node["@type"] == "WebPage" && node["url"] == url } }
        return { "codes" => codes, "http_status" => response.status, "final_url" => current }
      end
    rescue HttpTargetGuard::UnsafeTarget => error
      { "codes" => [ error.message ], "http_status" => nil }
    rescue NetHttpClient::TimeoutError
      { "codes" => [ "timeout" ], "http_status" => nil }
    rescue NetHttpClient::ResponseTooLarge
      { "codes" => [ "oversized_or_encoded_response" ], "http_status" => nil }
    rescue NetHttpClient::NetworkError
      { "codes" => [ "network_unavailable" ], "http_status" => nil }
    rescue URI::InvalidURIError
      { "codes" => [ "invalid_redirect" ], "http_status" => nil }
    end
  end
end
