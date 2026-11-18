# Cookies and storage

| Workflow | Browser state | Bound/purpose |
|---|---|---|
| New anonymous public GET/HEAD, modeON | No application Set-Cookie/session commit; no nonessential preference/analytics storage feature | Supported public route matrix; existing cookies may still arrive. Actual Chrome runtime is separately tested. |
| Login/setup/staff/member/protected previews | `_railpress_session`, Secure/HttpOnly/SameSiteLax host-only encrypted Rails session cookie | Browser-session cookie; browser restoration may retain it. Server-side credential limits remain authoritative. |
| Staff access | Staff token reference in essential cookie; only digest/server authority persisted |12h maximum with auth-version/clock checks, logout/recovery revocation. |
| Member access | Member token reference, proof/browser-binding state |1h maximum session,5min fresh proof for sensitive changes; policy/closure/version revocation. |
| Setup | Claimed setup nonce/CSRF in essential session |30min unclaimed secret,10min claim; one-time installation seal, secure first Owner independent of members. |
| Email verification | Browser-bound proof/CSRF; manual token or fragment handoff |15min signed one-use proof; no URL-query token. Actual browser fragment-removal execution remains an A05 deferred gate. |
| Dusk light/dark/system | CSS media preference or published site overlay | No visitor cookie/localStorage/sessionStorage/IndexedDB for appearance. |
| External-media link | No preloaded iframe/image/script | Following the disclosed link transfers a request to another website. Its storage policy is outside this mode. |
| Host/CDN/third-party tools | UNKNOWN until deployed inspection | Do not claim global zero-cookie or zero-personal-data behavior. |

CSRF and authenticated security cookies are deliberately preserved. ModeOFF does not authorize tracking or introduce it. Browser caching of public assets is ordinary resource caching, not a promise of no data anywhere on a device.
