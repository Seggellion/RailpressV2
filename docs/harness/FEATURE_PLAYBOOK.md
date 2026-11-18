# Native developer workflow — Harness v1

Use a disposable local clone/worktree and synthetic data. The supported qualified
runtime is native Linux (including this project's Ubuntu WSL qualification), Ruby
3.4.12/Bundler4.0.24, PostgreSQL16 and MySQL8.4. Native Windows/macOS runtime support
is NOT TESTED. No AI account or container is needed. Instructions are a developer
workflow, not production installation or deployment authorization.

## First run

Follow README's native prerequisites and docs/installation/NATIVE.md. Install the
locked bundle with scripts/native/bootstrap.sh. Provision test databases explicitly
with `python3 scripts/native/provision_databases.py --confirm-synthetic` in a fresh
checkout only when its documented loopback ports are free. It refuses existing
data/registries. Do not stop someone else's services, reuse an unidentified DB,
edit the guard or point it at a live site. A correctly preprovisioned developer
checkout may use its own already admitted synthetic registry.

```sh
bin/railpress-harness doctor
bin/railpress-harness plan reading_time > /tmp/railpress-reading-time-plan.json
cat /tmp/railpress-reading-time-plan.json
```

Doctor, plan and report do not create files or connect to a database. Doctor
checks the checkout/source inventory and reports the running Ruby; it is not a
full native-host, provider, TLS or production-readiness attestation. Planning shows
all proposed contents, root/source/policy binding and empty routes/migrations/
permission lists. Read that plan, then copy its review_sha256 into this command:

```sh
bin/railpress-harness scaffold reading_time --review COPIED_SHA256 --confirm-development
```

The digest is not an approval shortcut for an agent. A human or explicitly
authorized development task must review the concrete plan first. Changed source
or policy invalidates it. Existing files require matching private ownership
receipts; no overwrite option exists. Partial writes retain WRITING state and
need explicit `--resume` with the same still-valid review. Conflicts preserve work
and STOP. An idempotent repeat of an unchanged COMPLETE scaffold is safe.

Five files are proposed: a pure extension module, a controller returning404, an
unmounted view, a commented route proposal under documentation, and a Rails test.
No config/routes, capability registry, model/migration, default theme or app
initializer changes. Generic features deliberately get a failing acceptance-test
placeholder until implemented; reading_time is the complete harmless example.
Do not mount a public route before reviewing the core route/SEO/privacy contract.

## Verify independently on each engine

After explicit synthetic schema initialization using the guarded native runner:

```sh
bin/native_test postgresql --confirm-synthetic native:migrate_from_zero
bin/railpress-harness verify --engine postgresql --confirm-synthetic --suite example --feature reading_time
bin/railpress-harness verify --engine postgresql --confirm-synthetic
bin/railpress-harness verify --engine mysql2 --confirm-synthetic --suite example --feature reading_time
bin/railpress-harness verify --engine mysql2 --confirm-synthetic
bin/railpress-harness report
```

Initialize MySQL separately in an empty admitted schema too. `verify` defaults to
tests plus eager loading; it never prepares/migrates/resets a schema. All fixture
cleanup belongs only to the confirmed synthetic runner. DATABASE_URL, production
RAILS_ENV, DB connection overrides and Git environment substitution are refused.
Each native DB identity is independently verified before commands execute.

`verify --engine ENGINE --confirm-synthetic --suite quality` runs lint, Brakeman
and an offline dependency audit. Provision a verified advisory checkout explicitly
at .local/advisories first; missing advisory data is a refusal, not a vulnerability
PASS. Update advisories only as an explicit network action. For complete native
assets/eager-loading/TLS boot checks run scripts/native/quality.sh, whose documented
audit update fetches public advisories. Complete empty-migrate/schema-load evidence
uses scripts/native/qualify.sh ENGINE, which intentionally resets only admitted
disposable schemas; review that destructive test-fixture scope before running.

Verification logs/receipts are private under .local/harness/verifications. Reports
are local diagnostics, not signed attestations. Source drift marks proof stale;
failed/incomplete commands retain evidence. Review command results and raw logs,
not merely a receipt's existence. Existing inner worker deadlines remain intact;
the outer harness budget is3600monotonic seconds with owned-process cleanup.
Scaffolding and verification share one nonblocking checkout lock. Separate runs
get unique evidence directories; no run overwrites an earlier test receipt.

## Recovery, providers and stop conditions

Never use git reset/clean, remove unknown files or rewind a DB to tidy a failure.
Keep a source snapshot and read-only diff. Review only owned paths. Any Git
restore/revert/commit requires its own explicit local authorization; staged and
unrelated work must survive. Resume only hash-matching Harness changes. Unknown
ownership, changed source/receipt, private exposure or unsafe database identity
means STOP and retain evidence.

The CLI never invokes Codex, Claude, Grok, AI APIs or telemetry. Optional provider
commands are a separate explicit user action, with source-transfer review and
their own account/settings/permissions. AGENTS is guidance, not a sandbox that
can prevent an independently privileged process from running arbitrary commands.
Use provider/system permission controls; never infer that an unavailable client
is safe or tested. See COMPATIBILITY.md and TEST_MATRIX.md.
