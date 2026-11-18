# Privacy-first anonymous browsing

This mode limits nonessential anonymous visitor storage and automatic third-party resources. It is not a GDPR exemption, a legal compliance certification, an anonymity network or a promise of zero personal data. Hosts still receive IP/network requests and may retain logs.

New sites default ON. Schema13 adds the setting with database defaultOFF for existing rows, so an upgrade does not silently change an installed site's policy. The Owner can change Settings → Privacy; saving requires a current authenticated Owner, CSRF and the displayed policy revision. A stale editor receives a conflict instead of overwriting another save. OFF does not install analytics.

For supported public GET/HEAD actions—home/pages/posts/blog/taxonomy/search/404, robots/sitemap/RSS/news, public media and eligible theme resources—ON prevents an unauthenticated response from committing a Rails session or emitting Set-Cookie. Core adds resource/connect/frame restrictions and no-referrer. Cookies already held by a browser may still be sent; this feature does not erase browser history or third-party storage. Cacheable static assets do not create visitor state.

Authenticated staff/member workflows and authorized previews keep essential security state. Setup/login/recovery/email/Discord forms remain protected by CSRF and expiring credentials; there is no global session-middleware disable. Dusk light/dark/system remains a site-wide overlay/CSS choice, with no visitor preference cookie or browser storage. Themes cannot override core privacy/auth/SEO decisions.

Rich text and theme guards reject iframe/script and remote automatic-resource markup. The external-media content block instead explains the third-party request and offers an explicit HTTPS link. It does not preload or embed the destination. Following it leaves the site and the third party receives the request; no claim about that provider's cookies applies. Existing vetted executable themes are trusted code, not sandboxed packages.

The operator may run `RAILS_ENV=production bundle exec rake privacy:inspect` with the installed host's already configured private environment. It inspects eight fixed public routes in-process, records actual response/header/resource findings to a bounded0600private receipt and prints a JSON report. No supplied URL is fetched. Settings → Privacy displays a matching report or honestly reports that no snapshot is available. This is not Chrome execution, network capture, proxy/CDN inspection, zero-tracking attestation or legal advice.

Site archive writer v3 carries this nonsensitive setting; oldv2 imports preserve it when absent. Import staging preserves destination settings by default. Applying source settings requires separate explicit approval and destination conflict/reversal checks. Older strictv2 readers rejectv3; upgrade them before transfer. Legacy content-manifestv1 includes an advisory privacy extension, not a complete site-import authority.

Before public service, inspect actual TLS/proxy/CDN logs, third parties, authenticated providers, storage, retention and legal duties. A05 browser deferrals and historical clock/reliability conditions remain open. M16/A09 requalification and M17 approvals are separate.
