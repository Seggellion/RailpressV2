# Installer storage state and failure recovery — R8

The existing bootstrap authority, secure first Owner, CSRF, same-origin HTTPS, setup lock, optimistic revision, SecurityClock2 secret/claim limits and SQL/seal reconciliation remain authoritative.

Environment → Database → Storage → Identity → Owner → Appearance → Membership → Review → installed. A historical incomplete wizard lacking Storage is redirected to that step; safe nonsecret choices remain, downstream approvals must be repeated. Environment may report an unprepared media backend while still allowing the operator handoff step; Finish requires the chosen storage prerequisites.

Storage has two outcomes under the same lock: validated intent plus incomplete Storage when host settings/credentials need attention; or approved local configuration and acknowledged provider/durability limitations followed by Identity. No cloud API is invoked in either outcome. Invalid typed fields or stale/foreign claims cannot approve or probe another endpoint. Saving an earlier step invalidates later approval as before.

Apply host settings outside Railpress source, restart the owned web/worker services and resume using the still-valid claim. Same-boot restarts retain its bounded deadline; a new boot/expired claim needs a new operator secret. Nonsecret choices survive, prior Owner verifier is removed on a new claim. Never expand a deadline or change host time to resume setup.

Finish compares intent to process configuration and actual adapter/local prerequisites again before creating Site/Owner/Dusk/menus and the internal intent row in one transaction. A later mismatch refuses installation. A post-SQL seal failure reconciles only its own committing attempt. Once sealed, setup stays closed; it cannot reopen to change a media library. Readiness reports drift and missing worker/provider proofs separately.

An actual registered worker (not inline web execution) records a bounded configuration observation through the ordinary queue. Site Readiness also asks its actual worker to report. No report is inferred from a configuration file or a web request. Process restart/credential rotation requires the operator to reconcile settings and epoch. Expired observations cannot become fresh by a backward wall-clock step.

No automatic repair, IAM change, bucket creation, credential generation, physical purge or live Disk-to-GCS movement occurs. Missing media fails to existing accessible fallback. Preserve SQL, immutable objects and failed contexts; follow the separately qualified fresh-target/operator recovery contract. An old release pin remains evidence for its exact old bytes, not an attestation of this amended source.
