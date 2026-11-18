# Native restoration integrity

The executable adapter remains the isolated synthetic native profile. This
document does not authorize production restoration, data loss, signing, hosting
or an automatic code downgrade. SQL restore and filesystem/configuration restore
remain a maintenance operation with an explicitly accepted recovery point.

A successful database client exit is necessary, but insufficient. The updated
native operator independently verifies the expected tables and all authoritative
foreign-key definitions, enabled enforcement and existing orphan relationships.
A signed snapshot also binds column/default/index/check definitions, every
table's record count and byte-preserving row fingerprints, including schema and
migration metadata, content/revisions, Members, navigation and site configuration.
No raw account records or fingerprints become a public content export.

Before backup the operator quiesces writes and workers. Database evidence is
captured before and after the native dump; changed evidence refuses completion.
The new evidence lives inside the existing signed snapshot's site_report.
Snapshot format, product schema, jobs, configuration and SecurityClock version
remain unchanged. Earlier snapshots lacking this evidence are refused before
destructive intent by the updated validator. They are not silently upgraded,
restored with reduced checks or relabeled qualified. Retain the original point
and use a separately reviewed recovery procedure or a newly verified point.
The updated native operator must remain in use during compatible application
code reverts; a Puma code revert is not permission to downgrade recovery tools.

After SQL loading, schema and all captured records must match before any
credential cleanup. Only the existing documented cleanup is allowed afterward:
staff sessions/reset/previews are removed, preview-only media references are
removed and User auth_version advances once from the restored point. Full
record fingerprints are checked against that precise expected transformation.
Member account/identity data remains intact; restored deadline-bound credentials
remain subject to the newly rotated clock domain/epoch. Stable password verifiers
and install identity are conserved. No recovery turns a Member into staff.

Media/theme/bootstrap files retain signed inventories and copy checksum checks.
After copying, record integrity is rechecked; the security epoch must change and
scheduling stays held. The per-operation private verification journal transitions
RESTORING→VERIFIED only on completion, or FAILED on a caught error. Abrupt worker
termination can leave RESTORING and must never be read as completion. The outer
host still requires its full app/theme/user/business/job/proxy checks before
RESTORED and removing maintenance. A verification file alone is not traffic proof.

MySQL DDL replay is not transactional. It can retain partial DROP/CREATE results
after an error or interruption; PostgreSQL retains --single-transaction. Neither
adapter makes SQL plus external files atomic. Failures preserve maintenance,
operation identity and retained roots. Resume is explicit, under the same
snapshot/deployment/operation and verified quiescence; it is not an automatic
retry, SQL-down rollback or permission to overwrite an unrelated database.

Every spawned native command retains a private result sidecar with PID,
executable basename, monotonic start/duration, unchanged deadline, exit/signal,
termination signals and error code. RUNNING is recorded before waiting; a killed
operator may leave that incomplete record. No environment, credential contents,
SQL input or command argument secrets are included. The 30-second command bound
and three-second termination grace are unchanged. Operators must reconcile any
remaining owned child before resuming; no arbitrary PID is safe to signal.

Verification is bounded to 100,000 rows per table and 64 MiB of normalized,
Base64-encoded scalar record material per capture. Limits refuse; they never
truncate or waive integrity. Scalar bytes are encoded for hashing so native
binary-collation Unicode is preserved without lossy encoding conversion. Only
the observed PostgreSQL unbounded-varchar/text literal ARRAY coercion is
normalized in CHECK expressions; allowed values, other casts, predicates,
columns, indexes and constraints remain compared. This is not a general SQL
equivalence engine.

Current qualification, failures and platform/clock/browser/provider limits belong
to the exact release's evidence. A later successful test does not explain an
earlier interruption. Local source/evidence copies are not offsite backups,
production RPO/RTO, independent UTC or universal crash-recovery qualification.

## Bounded native preflight and phase evidence

Before destructive Host restore intent, and again before snapshot replay, core
checks available shared/database storage and the host guard. The current
synthetic model reserves an admission estimate of four times the larger of
current database allocation and the64MiB signed-record bound, plus1GiB database
working allowance, twice incoming/current shared bytes, and64MiB journal
allowance. Both storage paths must meet the combined amount; on WSL the host
must retain8GiB plus that amount. PostgreSQL uses pg_database_size; MySQL table
allocation is an estimate. This is conservative free-space admission, not an
actual quota reservation, universal peak-size guarantee or protection against
unrelated concurrent disk consumption. Unknown or insufficient measurements
refuse before SQL. Mid-operation space failure remains a recovery failure.

After stopping verified owned services, Host restore refuses remaining queue
registrations or visible target connections other than its verification
connection. It never kills an unknown writer. An empty/partial recovery target
may lack the queue table; target-session checks still apply. MySQL visibility is
limited by the least-privilege role; the synthetic trust model excludes hostile
DBA/same-UID actors. Concurrent application-writer restoration is unsupported.
Direct component tests of Snapshot/Database are not Host traffic admission.

The private verification journal binds operation/snapshot/deployment and a hash
of the sanitized physical target identity. It records attempt, monotonic phase
sequence/current/last-completed phase, safe error class/native code/SQLSTATE,
preflight model and elapsed time. SQL_COMPLETE follows actual client completion;
installation/schema/records/revocation/media/files/environment/clock/final phases
remain separate. It contains no arbitrary error message, SQL, credentials or
argument transcript. Explicit same-context resume retains the preceding attempt
byte-for-byte and refuses a changed target digest; at most eight attempts are
retained under existing bounded-root limits. An abrupt death can leaveRESTORING,
never completion. Old insufficient snapshot evidence remains refused; the signed
snapshot format, SecurityClock version and in-place restore semantics are
unchanged. Retained filesystem roots are not a pre-restore database backup or a
staged database replacement.
