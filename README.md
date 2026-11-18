# Railpress 2.0 — 2.0.0-alpha.1

Independent single-site Ruby on Rails CMS with native PostgreSQL16 and MySQL8.4, original Dusk, editorial revisions, media, menus, core-owned SEO, protected administration, optional public news and portable content.

This is preview source, not a production-qualified distribution. M16 remains BLOCKED; production hosting, independent release-time/signing authority, real GCS, provider/browser/accessibility and historical MySQL/clock findings remain open. No guaranteed uninterrupted updates, WCAG conformance or hosted CI success is claimed. Public source availability does not authorize deployment.

Core version **2.0.0-alpha.1**, channel **alpha**; Dusk **1.3.0**, Theme API **1**. See [version policy](docs/release/VERSION_POLICY.md), [release workflow](docs/release/GITHUB_RELEASE_WORKFLOW.md) and [known limitations](docs/release/KNOWN_LIMITATIONS.md). Optional Owner-enabled GitHub release checks use cached signed metadata. Main commits never become customer updates. One-button activation is limited to an explicitly qualified isolated synthetic native operator; other hosts show an unsupported state.

## Native developer setup

Install Ruby3.4.12/Bundler4.0.24, PostgreSQL16.16 tools, MySQL8.4.13, libvips8.18.7, Nginx1.30.6 for native host tests, and compatible native build libraries. Put Ruby/libvips on PATH and set RAILPRESS_PG_BIN and RAILPRESS_MYSQL_HOME to your own installed prefixes; set RAILPRESS_NGINX_BIN to the qualified /usr/sbin/nginx executable in its installed prefix. No repository-specific absolute path, private website access, AI account or container is required.

Run `scripts/native/bootstrap.sh` to install the locked bundle. Run `python3 scripts/native/provision_databases.py --confirm-synthetic` once in a fresh developer checkout. It refuses existing data, requires loopback dedicated roles/markers/private directories, and uses PostgreSQL55436/MySQL55404. For an independent qualification instance while those ports are occupied, use --qualification (fixed55636/55604 and distinct synthetic identities); the same marker/owner/data-root guards apply. An additional empty PostgreSQL probe is provisioned for archive/catalog tests. Never point fixtures at live or source databases. Secrets stay in ignored private .local state.

Run `scripts/native/qualify.sh postgresql` and then `scripts/native/qualify.sh mysql2`. Run `scripts/native/quality.sh` for assets/production boot/security/dependency/lint checks. Actual Chrome qualification is separate:360/768/1440CSSpx,200%zoom,keyboard/reduced-motion/manual accessibility. No other browser is qualified by these commands.

Production installation is an explicit operator action through `bin/railpress setup-token`, `doctor`, and `install --prepare-schema`/`install`; web/worker startup never creates a database. See docs/installation/NATIVE.md. Never use test provisioning on a live environment.

## Boundaries

Core owns identity, setup/admin/recovery/health/mail/security and SEO. Trusted vetted themes own approved public bodies only; Dusk packages are immutable, with user customizations in overlays. SecurityClock2 fails closed across unsupported clock domains; scheduling/release holds must be investigated, not bypassed. Content archives do not contain account secrets and are not database backups.

The private official website, editorial drafts, unapproved wordmark inputs, development history/recovery evidence and host-owned state are excluded. Generic fixtures are original synthetic examples. The optional official-news protocol uses a fixed public origin and explicit opt-in; it is not a private-site source dependency. Generic Owner-approved Dusk artwork, separate optional Member verification, and the developer Harness are implemented; live providers, browser/privacy and release gates remain separately qualified.

## Tool-neutral developer Harness

Start with `bin/railpress-harness doctor` and `plan reading_time`. Read the exact
proposed files and digest before `scaffold reading_time --review SHA --confirm-development`.
Scaffolding is for a disposable development checkout; no public route, migration
or capability is installed. `verify --engine postgresql --confirm-synthetic` and
the independent MySQL command run guarded tests/eager loading; `report` reads
private receipts. See docs/harness/FEATURE_PLAYBOOK.md for native setup, recovery,
quality checks, prompts and the tested harmless example. No AI account, key,
network upload, Docker or paid API is required by this CLI. AGENTS.md is canonical;
CLAUDE.md imports it. Provider-specific execution/limitations are in
docs/harness/COMPATIBILITY.md; documentation alone is not client qualification.

Railpress-owned source is MIT; retain LICENSE and THIRD_PARTY_NOTICES. Dependencies retain their own licenses. The older supplied official wordmark remains excluded. A02 uses the Owner-supplied original ruby-and-rails emblem (Seggellion, Altama Systems Incorporated), with explicit MIT copyright permission and trademark rights reserved, and default-dark protected administration; see docs/brand and docs/design for provenance and boundaries. Public Dusk appearance is separate. Security reports and support arrangements require an operator's documented contact; no service SLA is promised.
