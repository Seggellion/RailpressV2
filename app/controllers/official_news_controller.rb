class OfficialNewsController < ApplicationController
  def show
    site=Site.find_by!(singleton_key: 1)
    payload=OfficialNews::Provider.call(site: site)
    body=JSON.generate(payload)
    etag=%("#{Digest::SHA256.hexdigest(body)}")
    response.set_header("ETag", etag)
    response.set_header("Cache-Control", "public, max-age=300, must-revalidate")
    modified=payload["items"].map { |row|Time.iso8601(row["modified_at"]) }.max
    response.set_header("Last-Modified", modified.httpdate) if modified
    if request.headers["If-None-Match"].to_s.split(",").map(&:strip).include?(etag)
      head :not_modified
    else
      render json: payload
    end
  rescue OfficialNews::Schema::Invalid
    render json: { error: "official_news_unavailable" }, status: :not_found
  end
end
