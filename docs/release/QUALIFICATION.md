# Reproducing native qualification

Install README prerequisites and the locked bundle. In a fresh checkout run python3 scripts/native/provision_databases.py --confirm-synthetic. It refuses existing state/registries and occupied ports. --qualification uses a separate fixed55636/55604 instance and dedicated identities; it does not replace existing services. The empty PG probe and main database have distinct roles/markers.

Run scripts/native/qualify.sh postgresql and scripts/native/qualify.sh mysql2 independently, then scripts/native/quality.sh. The former intentionally clears only admitted disposable application schemas to compare migrations/schema-load, then runs complete tests and eager loading. Actual server identity/role/marker/ownership/private-root and8GiB host guard stay mandatory. Never use these commands on valuable data.

bin/railpress-harness doctor/plan/verify/report provide provider-independent orchestration. Review an example plan before explicitly scaffolding into a disposable checkout; do not include generated example files in the release inventory. Codex/Claude/Grok account/runtime gates remain as documented in docs/harness/COMPATIBILITY.md; no AI provider call is required.

Record exact Git commit/tree, source file hashes, test counts/seed/failures, native versions and private receipts. A green suite is not actual Chrome/screen-reader, real GCS/OAuth/SMTP, reference-host, production signing or deployment proof. No certificate warning bypass or trust-store change belongs in this workflow.
