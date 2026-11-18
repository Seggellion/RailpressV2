# M07 native qualification fixture, explicitly required only in a disposable
# copied release/test server. Not loaded by the application or an M08 menu store.
module DuskNavigationContractFixture
  module_function
  def call(site:)
    raise "wrong fixture" unless site.title == "Aster Studio" && site.canonical_origin == "https://localhost:59107"
    nav = Themes::Navigation
    page = lambda do |slug, label|
      record = Page.publicly_visible.find_by(slug: slug)
      record && nav.item(label: label, url: Seo::RouteRegistry.content_path(record, site))
    end
    guide = page.call("docs", "Working together")
    about = page.call("about", "Our approach")
    services = page.call("services", "Services")
    learn = about && nav.item(label: "Studio", url: about.url, children: [ services, guide && nav.item(label: "Guides", url: guide.url, children: [ guide ]) ].compact)
    nav.slots(primary: [ services, learn, nav.item(label: "Journal", url: "/blog"), page.call("contact", "Contact") ].compact,
      footer: [ page.call("privacy", "Privacy"), guide ].compact, documentation: [ guide, services ].compact)
  end
end
