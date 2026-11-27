Rails.application.routes.draw do
  get "up" => "health#show", as: :rails_health_check
  get "health/release" => "release_health#show"
  get "setup/storage-guide" => "setup#storage_guide", as: :storage_setup_guide
  get "setup" => "setup#show"
  post "setup/claim" => "setup#claim", as: :claim_setup
  post "setup/steps/:step" => "setup#advance", as: :advance_setup
  post "setup/complete" => "setup#complete", as: :complete_setup
  get "login" => "sessions#new"
  post "login" => "sessions#create"
  delete "logout" => "sessions#destroy"
  get "password/recovery" => "password_recoveries#new", as: :password_recovery
  post "password/recovery" => "password_recoveries#create"
  get "password/reset" => "password_recoveries#edit", as: :password_reset
  patch "password/reset" => "password_recoveries#update"
  get "login/members/login" => "members#new", as: :members_login
  post "login/members/email" => "members#request_email", as: :members_email
  get "login/members/verify" => "members#verify", as: :members_verify
  post "login/members/verify" => "members#complete_email"
  post "login/members/discord" => "members#start_discord", as: :members_discord
  get "login/members/discord/callback" => "members#discord_callback", as: :members_discord_callback
  get "login/members/account" => "members#show", as: :members_account
  post "login/members/email/change" => "members#change_email", as: :members_change_email
  post "login/members/discord/disconnect" => "members#disconnect", as: :members_disconnect
  delete "login/members/logout" => "members#destroy", as: :members_logout
  post "login/members/close" => "members#close", as: :members_close
  get "login/members/export" => "members#export", as: :members_export
  get "api/public/v1/news.json" => "official_news#show", as: :official_news, format: false
  get "admin" => "admin/dashboard#index", as: :admin
  post "admin/quick-draft" => "admin/dashboard#create", as: :admin_quick_draft
  namespace :admin do
    get "privacy" => "privacy#show"
    patch "privacy" => "privacy#update"
    get "accounts" => "accounts#show"
    patch "accounts" => "accounts#update"
    get "official-news" => "official_news#show"
    patch "official-news" => "official_news#update"
    post "official-news/review" => "official_news#review", as: :official_news_review
    get "session-state" => "session_states#show"
    get "customize" => "themes#customize"
    resources :imports, only: [ :index, :create, :show ] do
      member do
        get :status
        post :inspect_archive
        post :approve
        post :activate
        post :retry
        post :reverse_batch
        post :preview_appearance
        post :cleanup
      end
    end
    resources :site_exports, only: [ :create, :show ] do
      get :download, on: :member
    end
    get "activity" => "activity#index"
    get "readiness" => "readiness#show"
    post "readiness" => "readiness#create"
    delete "readiness/:id" => "readiness#destroy", as: :readiness_run
    post "menus/stop-preview" => "menus#stop_preview", as: :menus_stop_preview
    resources :menus, only: [ :index, :create, :edit, :update, :destroy ] do
      post :preview, on: :member
    end
    resources :contents, only: [ :index, :new, :create, :edit, :update ] do
      post :preview, on: :member
      get :revisions, on: :member
    end
    resources :exports, only: [ :new, :create ]
    resources :media_assets, only: [ :index, :new, :create, :show, :update, :destroy ]
    resources :terms, only: [ :index, :create ]
    resources :users, only: [ :index, :create, :update, :destroy ]
    get "settings" => "settings#edit"
    patch "settings" => "settings#update"
    get "themes" => "themes#index"
    post "themes/uploads" => "themes#upload", as: :theme_uploads
    post "themes/uploads/:id/resume" => "themes#resume_upload", as: :resume_theme_upload
    post "themes/revert" => "themes#revert", as: :themes_revert
    post "themes/stop-preview" => "themes#stop_preview", as: :themes_stop_preview
    resources :themes, only: :destroy do
      post :overlay, on: :member
      post :preview, on: :member
      post :activate, on: :member
    end
    get "updates" => "updates#index"
    post "updates/stage" => "updates#create", as: :updates_stage
    post "updates/checks" => "updates#checks", as: :updates_checks
    post "updates/check-now" => "updates#check_now", as: :updates_check_now
    post "updates/combined" => "updates#combined", as: :updates_combined
    get "modules/add" => "module_catalog#review", as: :module_catalog
    post "modules/add" => "module_catalog#create", as: :module_catalog_requests
    get "modules/requests/:id" => "module_catalog#show", as: :module_request
    post "modules/requests/:id/cancel" => "module_catalog#cancel", as: :cancel_module_request
    get "modules" => "modules#index"
    post "modules" => "modules#create"
    patch "modules/:id/enable" => "modules#enable", as: :enable_module
    patch "modules/:id/disable" => "modules#disable", as: :disable_module
    get "seo" => "seo#show", as: :seo
    get "seo/sitemap" => "seo#sitemap", as: :seo_sitemap
    get "seo/indexability" => "seo#indexability", as: :seo_indexability
    get "seo/diagnostics" => "seo#diagnostics", as: :seo_diagnostics
    get "seo/diagnostics/:id" => "seo#diagnostic", as: :seo_diagnostic, constraints: { id: /\d+/ }
    post "seo/execute" => "seo#execute", as: :seo_execute
  end
  get "admin/media_assets/:id/file" => "media_files#private_file", as: :private_media_file
  get "media/:content_id/:public_id/:variant" => "media_files#show", as: :public_media_file
  get "preview/:preview_id/media/:public_id/:variant" => "media_files#preview", as: :preview_media_file
  get "theme-assets/:theme_key/:version/:digest/:file" => "theme_assets#show", as: :theme_asset, constraints: { version: /[0-9a-z.-]+/, file: /[a-z0-9._-]+/ }, format: false
  get "theme-preview-assets/:theme_key/:version/:digest/:file" => "theme_assets#preview", as: :theme_preview_asset, constraints: { version: /[0-9a-z.-]+/, file: /[a-z0-9._-]+/ }, format: false
  get "theme-media/:overlay_id/:kind" => "theme_assets#media", as: :theme_media
  get "preview/:id" => "content_previews#show", as: :content_preview
  get "blog" => "public_contents#archive"
  get "blog/:slug" => "public_contents#post"
  get "category/:slug" => "public_contents#category", as: :category_archive
  get "tag/:slug" => "public_contents#tag", as: :tag_archive
  get "search" => "public_contents#search", as: :search
  get "robots.txt" => "public_contents#robots"
  get "sitemap.xml" => "public_contents#sitemap", defaults: { format: "xml" }
  get "feed.xml" => "public_contents#feed", defaults: { format: "xml" }
  Railpress::Extensions.registry.mount(self)
  root "public_contents#home"
  get ":slug" => "public_contents#page", constraints: { slug: /[^\/]+/ }
  get "*slug" => "public_contents#page", format: false
end
