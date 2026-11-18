# Railpress developer contract — Harness v1

This is the canonical shared contract for humans and coding assistants. Read
docs/harness/FEATURE_PLAYBOOK.md and ARCHITECTURE_MAP.md before implementation.
CLAUDE.md imports this file; other tool gateways must not duplicate its rules.
Higher-priority instructions and explicit Owner scope still apply. A plan does
not authorize production changes, publication, account use or source transfer.

## Start and stop

- Inspect Git status, HEAD, index/staging, source ownership and current evidence.
  Preserve unrelated work, historical findings and public/private boundaries.
- Write a bounded feature plan with affected contracts, threats, acceptance,
  exact files and recovery. Review before mutation. Do not auto-delegate work.
- Use bin/railpress-harness doctor and plan FEATURE; scaffold only in an explicitly
  confirmed development checkout after inspecting the exact plan and digest.
- Never stage, reset, clean, commit, push, deploy, sign with real keys, publish
  articles or contact remote services without the relevant explicit action.
- STOP on unknown target/ownership, source or credential leakage, unsafe path,
  stale/conflicting plans, unauthorized data visibility or unexplained failures
  affecting correctness/safety. Preserve failed evidence; no hidden retries.

## Architecture invariants

- Core owns setup/admin/auth/recovery/health/mail, capabilities and SEO head.
  Theme API v1 owns approved public bodies only. Themes are trusted executable
  packages, immutable by digest; customize through versioned overlays.
- Use authoritative Editorial, Navigation, Themes, Privacy, Identity/Membership
  and Portability services. Never add endpoint authority by hiding a link.
- Drafts, not-due content and private previews stay private. Preserve revision,
  optimistic concurrency, author identity and transactional mutation checks.
- Canonical origin, redirects, indexing, sitemap and route ownership belong to
  core SEO policy; never trust arbitrary Host headers or theme overrides.
- SecurityClock2 controls security deadlines. Keep reboot/domain/rollback
  refusal, credential revocation and scheduling/release holds. Never change
  clocks or expand deadlines to manufacture passing results.
- First Owner remains local and distinct from Member verification. No automatic
  Member-to-staff elevation. Preserve CSRF, essential sessions and recovery.
- Archive/export is versioned content portability, not a database backup. Keep
  approvals, collision/reversal checks and secret exclusions. Schema changes
  require portable expand/backfill/contract design; no automatic SQL-down restore.
- Privacy-first anonymous mode minimizes nonessential cookies/storage/requests;
  authenticated security and hosting logs are separate. No GDPR exemption,
  universal compliance, zero-personal-data or uninspected no-IP-log claims.

## Verification and delivery

- Native Ruby/Bundler, PostgreSQL16 and MySQL8.4 only. No Docker/Compose/Kamal,
  container services or source/production database access. Before every fixture
  operation verify exact synthetic DB/role/instance and private storage/cache/mail.
- Verify both engines independently through the guarded native runner. Run
  focused tests, relevant full regressions, assets/eager loading, lint, Brakeman,
  dependency audit and failure cases. Never weaken assertions or hide partial DDL.
- Chrome only for browser qualification: 360/768/1440 CSS px, 200% zoom, keyboard,
  focus, reduced motion and accessibility. HTTP/static checks are not browser
  storage/network proof. Record unavailable gates as NOT TESTED.
- New generic code/assets must have clear rights; exclude private site drafts,
  operational state, keys, account data and uncleared material from core/history.
- No automatic AI API calls, source upload, telemetry, account/key requirement or
  production agent. Provider tools have separate account/data policies; obtain
  explicit source-transmission authorization before optional remote workflows.
- Record exact source fingerprint, commands, counts/failures, environment,
  artifacts and open gates. PASS is scoped; CONDITIONAL/BLOCKED/NOT TESTED remain
  explicit. Do not turn a local result into hosting, CI, release or launch proof.
