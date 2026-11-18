# Protected administration dark design

The core-owned account, installer and administration layouts use a fixed dark design. There is no personal preference, database setting, appearance cookie or public-theme mode in this feature. Dusk and alternative public themes keep their existing appearance; site-wide public light/dark/system is a separate amendment.

`app/assets/stylesheets/protected_dark.css` scopes every selector to `body.core` or a `.core` descendant, including reduced motion, forced colors and print. `public-content` never opts into these tokens. Existing structural styles remain intact; the protected layer follows them in Propshaft's stylesheet order. Public theme package files, renderer API, overlays and versions are unchanged. Core catastrophic static error pages also default dark without relying on a working application/theme.

| Semantic role | Color |
|---|---|
| Background / surface / elevated / hover |#101419 /#181e25 /#222b35 /#2b3847 |
| Primary text / muted / links |#eef2f6 /#b8c4d1 /#a8d8ff |
| Structural divider / interactive boundary |#465668 /#7c8fa4 |
| Control fill / action fill / action text / hover |#111820 /#b9dbff /#10243a /#d3e8ff |
| Focus and selection |#ffd166 (selection uses action fill with action text) |
| Positive text / fill / border |#b9f1cf /#173c30 /#68b990 |
| Warning text / fill / border |#ffe2a4 /#45331a /#d9a441 |
| Error text / fill / border |#ffd0d7 /#43242b /#ff8d9d |
| Disabled text / fill |#aab6c5 /#29323e |

Normal text targets4.5:1; relevant interactive boundaries and focus target3:1. The32 declared text/control/status/focus pairs measure at least5.176:1 by sRGB relative luminance. Decorative separators do not serve as an interactive affordance. Logo graphics are documented separately. Actual computed-style/Chrome state checks remain the qualification authority; token arithmetic alone is not a complete accessibility audit.

Coverage includes dashboard metrics/cards/news/activity, Page/Post native and visual editors/outlines/revisions/scheduling, taxonomy, media upload/details/missing states, menu editor/reorder/conflict/drop/publish, themes/customize/recovery, SEO, site settings/accounts, readiness, native updates, manifest/complete imports/exports, login/recovery/setup, flash/status/error panels and session-verification warnings. Text, status words, labels and roles accompany color. Visible keyboard focus is a3px amber outline with3px separation;44px control targets and responsive navigation/reflow retain the prior layout. Native controls use `color-scheme:dark`; placeholders and disabled values remain legible. Rich content images retain their own colors and alt/caption requirements.

Protected browser failures use the escaped `shared/core_error` template in the core layout, preserving each original HTTP status/message and all authorization/CSRF/throttle/clock/storage/last-Owner checks. No account/theme lookup is needed to render this failure. JSON/non-HTML callers retain their exact plain-text refusal, and public protocol errors retain their prior behavior. API/health/binary responses have no visual theme. No security hold is dismissed or recolored into success.

Print switches protected content to light backgrounds and dark text with controls/navigation omitted. Forced-color mode keeps system highlight/boundary behavior. Reduced motion disables protected animation/transitions/smooth scrolling without changing a host setting. No screen-reader or WCAG-conformance claim follows from CSS, automated checks or Chrome screenshots alone. Consult the exact A02evidence and preserve historical M05/M08 findings and M16BLOCKED.

## Original emblem correction

The primary identity is now the Owner-supplied ruby-and-rails raster emblem; see docs/brand for exact source, reviewed resampling and separate copyright/trademark authorization. The topbar and expanded sidebar link pair a decorative image with readable Railpress text; the collapsed native disclosure pairs the same image with Administration menu. Login/setup/recovery/core failures share the core header helper. Static error fallbacks include the same brand and fingerprinted PNG/ICO metadata. Palettes, roles, focus, server policies and public Dusk remain unchanged. The prior folded-page design is preserved as a non-active concept; no A07 adoption is implied.
