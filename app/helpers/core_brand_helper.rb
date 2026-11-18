module CoreBrandHelper
  MARK = "/brand/railpress-ruby-rails-192-28775b14513e2ba1.png".freeze
  PNG_ICON = "/brand/railpress-ruby-rails-32-629b8e8d6aeaad5c.png".freeze
  PNG_ICON_16 = "/brand/railpress-ruby-rails-16-cc8837908c5a2c44.png".freeze
  PNG_ICON_48 = "/brand/railpress-ruby-rails-48-b0cb5684c0a79164.png".freeze
  TOUCH_ICON = "/brand/railpress-ruby-rails-180-0d5c2d2c8cd14882.png".freeze
  APPLICATION_ICON_192 = "/brand/railpress-ruby-rails-192-28775b14513e2ba1.png".freeze
  APPLICATION_ICON_512 = "/brand/railpress-ruby-rails-512-f7baa2ecf10b116f.png".freeze
  ICO_ICON = "/brand/favicon-ruby-rails-12450c03d2c8e308.ico".freeze

  def core_brand_icon
    image_tag(MARK, alt: "", width: 32, height: 32, class: "brand-mark", aria: { hidden: true })
  end

  def core_brand_label
    safe_join([ core_brand_icon, "Railpress" ])
  end
end
