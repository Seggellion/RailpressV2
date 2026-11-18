module Seo
  module Redirects
    module_function
    def published!(content)
      return unless Policy.visible?(content)
      site = Site.find_by!(singleton_key: 1)
      path = RouteRegistry.content_path(content, site)
      old = content.last_public_path
      Redirect.where(source_digest: Digest::SHA256.hexdigest(path), target_content_id: content.id).delete_all
      if old.present? && old != path && RouteRegistry.redirect_source?(old)
        existing = Redirect.lock.find_by(source_digest: Digest::SHA256.hexdigest(old))
        raise Editorial::Workflow::Invalid, "Historical URL belongs to another item" if existing && existing.target_content_id != content.id
        Redirect.create!(source_path: old, target_content: content) unless existing
      end
      content.update_columns(last_public_path: path) if content.last_public_path != path
    end
    def resolve(path, site)
      return unless RouteRegistry.redirect_source?(path)
      row = Redirect.find_by(source_digest: Digest::SHA256.hexdigest(path))
      target = row&.target_content
      return unless Policy.visible?(target)
      destination = RouteRegistry.content_path(target, site)
      destination unless destination == path
    end
  end
end
