# Data-flow inventory

| Surface | Data/storage/network | Scope and limit |
|---|---|---|
| Anonymous public content/search/SEO | Public request path/search terms, IP/connection and potential host logs; no application visitor account/identifier | ON suppresses anonymous cookie/session commit and automatic external resources. It cannot remove network metadata or inspect live host logs. |
| Dusk navigation/appearance/artwork | Local versioned CSS/JS/approved images, CSS system preference | No preference persistence, tracking pixel, external font or device-fingerprinting feature added. Source inspection is not runtime browser proof. |
| Public media/theme resources | Local bytes, content visibility/active-package checks | ON policy where controllers execute; static middleware responses must be checked separately in real topology. |
| Staff/setup/recovery/previews | Encrypted session cookie, server token digests, role/version/expiry, activity/security journal | Essential requested security, private persistent state, CSRF and SecurityClock2 retained. No anonymous-mode privilege changes. |
| Members/email | Address, signed mailbox proof, attempt/session/throttle records, mail-provider processing | User-selected protected workflow, not ordinary browsing. SMTP acceptance alone is not inbox/verification proof. |
| Discord | User-selected provider navigation, immutable subject, optional email claim, transient grant exchange | Explicit disclosure/state/S256/issuer/exact callback; no automatic anonymous provider call. Live integration separately qualified. |
| Optional official news/update diagnostics | Host-origin public requests through existing bounded background/operator clients | Opt-in/background, not triggered by an anonymous page render. Provider receives server network metadata. |
| Activity/errors/access logs | Bounded app activity, optional request/IP/referrer/user-agent logging in host/proxy/CDN/system tools | Default appwarn/search filtering reduces routine data; operator overrides and infrastructure remain unknown until inspected. Hashing identifiers is not proof of anonymisation. |
| Portable content/export | Ordinary content/settings, now privacy boolean in site archivev3 | Excludes authentication/provider authority. Plaintext content packages require appropriate access/retention; they are not full backups. |
| Posture diagnostics | Fixed public response statuses/header flags/resource counts/body checksums and host timestamp | Private bounded snapshot; no query/token/cookie values, browser execution, device fingerprint or host-log attestation. |

Inventory browser mechanisms explicitly at A08/A09: cookies, localStorage, sessionStorage, IndexedDB, CacheStorage/service workers, pixels, embeds, fonts/CDNs, fetch/XHR/beacons and device-fingerprinting APIs. Their absence cannot be certified from a cookie header alone. Inspect each approved extension/theme, reverse proxy, CDN and error-reporting integration before deployment.
