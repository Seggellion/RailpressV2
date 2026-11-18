module Editorial
  module Terms
    module_function
    def create!(actor:, kind:, name:, slug:)
      Site.transaction do
        Site.find_by!(singleton_key: 1).lock!
        actor.lock!
        Identity::Capabilities.require!(actor, :publish_others)
        raise Workflow::Invalid, "Choose category or tag" unless %w[category tag].include?(kind)
        taxonomy = Taxonomy.create_or_find_by!(kind: kind)
        taxonomy.terms.create!(name: name, slug: slug)
      end
    end
  end
end
