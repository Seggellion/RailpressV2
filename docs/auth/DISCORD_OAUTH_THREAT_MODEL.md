# Discord membership threat model

The browser and provider payload are untrusted until the applicable proofs succeed. Host-owned provider configuration is a separate trusted boundary; ordinary staff, themes and imports cannot supply endpoints, client secrets, callbacks or provider adapters.

| Threat | Enforced boundary | Qualification target |
|---|---|---|
| Login CSRF/state theft |256bit per-flow state and independent browser nonce, essential encrypted session, explicit CSRF POST start|Wrong/missing/foreign/replayed state fails before exchange|
| PKCE interception |S256 random verifier encrypted server-side; verifier never browser query or logs|Wrong verifier/code consumes flow and fails|
| Issuer mix-up |Required iss exactly https://discord.com|Missing/forged/trailing-variant issuer rejected before exchange|
| Browser form navigation |Core CSRF POST returns local confirmation, then an explicit fixed-provider link; strict form-action self/script-src none retained|Chrome credential-free comparison confirms form redirect stays on source, explicit link reaches target; actual installer/member walkthrough remains separately required|
| Callback/open redirect |Canonical origin + exact /login/members/discord/callback, never Host-derived destination or return_to|Wrong host/callback cannot exchange or redirect to arbitrary site|
| Code reuse/races |State consumption commits before network; unique code digest until expiry; Site locks|One accepted identity/link; duplicate code refused without second exchange|
| Config/key rotation during flow |HMAC fingerprint of fixed host settings checked before and after exchange|Changed client/callback/secret invalidates pending flow|
| SSRF/rebinding/redirects |Fixed three HTTPS Discord endpoints, every DNS answer public, pin chosen IP, TLS peer+hostname verification, no proxy/env redirect/retry|Private/mixed DNS, deceptive URL, redirect, bad TLS fail closed|
| Resource exhaustion |DNS2s, socket2s, entire exchange/user/revocation5s,16KiB response body, bounded parser headers/nesting, throttles and hard state caps|Oversize/compression/invalid JSON/deadline tests|
| Forged identity/privilege claims |User obtained only through authenticated server backchannel; immutable decimal subject; no browser payload/roles|Malformed subject, bot/system, extra staff/guild claims cannot create staff|
| Email collision/takeover |No auto-merge by mailbox; strict verified claim when required; explicit fresh current Member confirmation for link|Absent/unverified/changed email, duplicate identity and competing links fail safely; explicit links request identify+email even when ordinary sign-in is identify-only|
| Token leakage |Transient bearer only, no persistent refresh; redacted params/code/state/errors; no-referrer/no-store core callback|No secret in source/DB/export/ordinary logs; reverse-proxy log policy separately qualified|
| Provider failure/revocation |Error/denial aborts, no automatic fallback or Member creation; bounded local session|Revoked/unavailable synthetic grant denied; max1hour local-session window disclosed|
| Staff account takeover |Separate Member and staff tables/session keys; exact User capability type and locked live Owner policy checks|Member token and matched staff email cannot authorize /admin|

Primary sources consulted on2026-11-14America/Vancouver: [Discord OAuth2](https://raw.githubusercontent.com/discord/discord-api-docs/main/developers/topics/oauth2.mdx) documents confidential code flow, state, issuer identification, fixed endpoints and recommends PKCE. [Discord User](https://raw.githubusercontent.com/discord/discord-api-docs/main/developers/resources/user.mdx) defines immutable id and optional email/verified claims. [RFC9700](https://www.rfc-editor.org/rfc/rfc9700.html) informs code-flow/PKCE/redirect/replay protections. The current Discord code example does not enumerate S256 parameters; actual live application PKCE support must be verified before setting pkce_s256_verified. No discovery/API endpoint was contacted, no real credentials used, and no live callback outcome is inferred from this documentation or synthetic tests.

Synthetic browser/provider qualification is explicitly separate from actual Discord consent/token exchange/revocation/TLS/network availability. M17 live activation needs owner-held application registration, exact callback, current supported S256 behavior, minimal scopes, privacy/terms review, approved credentials and actual end-to-end observation. Native trusted-time/release gates and M05/M08 historical findings remain open.

A05 failure injection found that cleanup in ensure could otherwise run after an outer timeout. Revocation now uses only the remaining monotonic five-second sequence budget; exhaustion fails local completion and cannot start a fresh cleanup budget. A timed-out remote grant may remain at the provider until expiry/revocation. No retry, persisted token or instant-remote-revocation claim.
