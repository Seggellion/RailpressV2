module Themes
  module Smoke
    module_function
    def call(path)
      Railpress::ThemeSmoke.call(path, keys: Storage.trusted_keys, root: Rails.root, work_root: Storage.root)
    end
  end
end
