# Storage readiness and authentication qualification — R8

Local configuration and provider capability are separate facts. Setup's **Verify Storage Configuration** submits only typed nonsecret intent under its existing claim/CSRF/lock/revision. It performs no ADC discovery, metadata request, token exchange or bucket operation. Disk verification uses one new random private sentinel and removes that sentinel only. GCS remains provider NOT TESTED.

| Status | Meaning |
|---|---|
| CONFIGURED | Valid local intent, matching running adapter and visible declared credential prerequisite; not a cloud connectivity claim. |
| VERIFIED | A particular executed check passed (for example, Disk sentinel I/O). Never inferred for GCS from a file or environment variable. |
| ACTION REQUIRED | Invalid/missing/conflicting settings, host handoff, configuration drift or mismatching worker. |
| UNAVAILABLE | A required dependency/provider cannot be reached; retain its failure evidence, never change endpoint or credentials automatically. |
| UNSUPPORTED | Outside the typed contract, such as browser credential upload, executable federation source, custom endpoint, public bucket or automatic media migration. |
| NOT TESTED | Provider/IAM/token/retention/durability proof absent, missing/stale worker report or unqualified remote worker. |

Site Readiness exposes storage configuration and storage-process agreement independently. Installed typed intent is checked before media mutation/delivery. A legacy installation without intent remains explicitly unbound and needs operator review, not an inferred migration. Runtime environment is captured on boot; every affected web/worker service must restart after changes. The operator configuration epoch signals rotations without storing keys.

Worker observations require actual Solid Queue Worker registration, process role and current PID/hostname. Reports are keyed by registration and serialized under the existing Site row lock: one matching worker cannot overwrite another worker's discrepancy. Every currently registered live local worker must have a matching installation-bound SecurityClock2 observation (180 seconds). Missing, expired or remote observations are NOT TESTED; any fresh mismatch is ACTION REQUIRED. Dead local registrations are excluded using a non-signalling process-existence check. Multi-host worker admission and principal equivalence remain unqualified. Readers bypass SQL query cache; readiness cache identity includes registration/configuration/freshness, so new workers and expired evidence invalidate it. A fresh report is not a bucket permission or token test.

| Authentication choice | Local evidence and supported configuration | Qualification limit |
|---|---|---|
| ADC automatic (default) | Maintained Google ADC factory; explicit file/standard user/system lookup; synthetic complete installer and factory delegation. | No real discovery/token/provider call; implicit long-lived key sources refused. |
| ADC attached identity | Explicit attached hint with no conflicting local file; normal maintained factory at runtime. | Metadata server, identity, scopes and IAM NOT TESTED. No cloud/container host qualification inferred. |
| ADC federation | Private operator external-account configuration outside all repositories; executable source refused; native external hosts can supply supported federation config. | Real pool/provider, subject-token source, STS exchange and impersonation NOT TESTED. |
| ADC native/development | Explicitly provisioned supported ADC file; development user ADC clearly distinguished from production workload identity. | A successful local gcloud login is not production readiness. |
| Explicit service-account file | Separate selected fallback, private owned regular file outside releases/Git; maintained service-account factory; complete synthetic installer. | No real key generated/read/copied, token issuance or provider grant qualification. |
| Missing/conflicting/unsafe source | Local rejection and actionable operator handoff; no credential fallback or metadata probe. | Cannot approve missing native/federation credentials. |

Only nonsecret source status enters HTML. Credential contents, locator paths, tokens and private keys do not enter Site settings, SQL intent, CMS exports, logs or backup manifest metadata. A source-locator digest is an internal consistency identifier, not a proof of principal identity. Actual external-account files and subject-token sources require separate operator review and custody.

Actual GCS admission requires separately approved disposable resources/prefix and bounded costs: identity, private bucket metadata, effective bucket-get/object-create/get permissions, write/read/generation/checksum/denial behavior, retained objects, actual lifecycle/versioning/soft-delete/retention, and fresh-target recovery. Railpress does not physically delete cloud objects. The adapter's existing failure taxonomy distinguishes MISSING, INACCESSIBLE, MISMATCH and UNKNOWN; none substitutes another object. Live tests are NOT TESTED in R8.
