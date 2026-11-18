module Portability
  module Fingerprint
    module_function
    def current(item)
      record = case item.kind
      when "author" then User.find_by(id: item.target_id)
      when "content" then Content.find_by(id: item.target_id)
      when "revision" then ContentRevision.find_by(id: item.target_id)
      when "term" then Term.find_by(id: item.target_id)
      when "media" then MediaAsset.find_by(id: item.target_id)
      when "menu" then Menu.find_by(id: item.target_id)
      end
      return nil unless record
      values = record.attributes.except("created_at", "updated_at")
      values = record.attributes.slice("id", "role", "auth_version") if item.kind == "author"
      values["terms"] = record.content_terms.order(:stage, :term_id).pluck(:stage, :term_id) if item.kind == "content"
      values["tree"] = record.tree if item.kind == "menu"
      Digest::SHA256.hexdigest(Railpress::SiteArchive.canonical(values))
    end
  end
end
