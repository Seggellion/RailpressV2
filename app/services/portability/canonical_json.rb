module Portability
  module CanonicalJson
    module_function
    def value(object)
      case object
      when Hash then object.keys.sort.to_h { |key| [ key, value(object.fetch(key)) ] }
      when Array then object.map { |item| value(item) }
      else object
      end
    end
    def dump(object)
      JSON.generate(value(object))
    end
  end
end
