Rails.application.config.after_routes_loaded do
  Administration::Navigation.validate!
end
