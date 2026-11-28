NeutralProbe::Engine.routes.draw do
  root "probes#show"
  get "presentation" => "probes#presentation"
end
