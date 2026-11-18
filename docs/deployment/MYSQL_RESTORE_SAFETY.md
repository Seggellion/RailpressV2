# Native MySQL restore cancellation

MySQL DDL can leave a partial schema. Reaping its CLI does not prove its server
query stopped. The synthetic adapter keeps its 30-second command deadline and
3-second signal grace. MySQL restore uses SIGTERM, then SIGKILL if necessary.
SIGINT is insufficient: the actual client can interrupt one statement and
continue consuming later batch statements. A09-R2 demonstrated that behavior
with an interrupted SLEEP followed by a canary INSERT. SIGTERM stops input;
the independent owned-session gate below cancels any surviving server query.

A private input copy prepends `SELECT CONNECTION_ID();` to the unchanged dump
bytes. The original snapshot is never rewritten. Batch, unbuffered, header-free
output and disabled reconnect bind that ID to every subsequent statement. A
separate least-privilege connection stays open throughout the command and checks
the exact session afterward. It requests KILL CONNECTION only for that ID with
the expected username and database, then independently verifies absence. A three-second monotonic decision budget is
checked around control IO and completion; it is not an absolute transport SLA.
No global grants, instrumentation or durability changes are required.

`mysql-restore-unsafe.json` remains if identity or quiescence cannot be verified.
The fixture must not be automatically inspected as stable, cleaned or reused.
New restores refuse the marker; the test guard aborts before data cleanup. Keep
all logs, session output and failed verification contexts. An operator must
establish quiescence and a valid recovery plan before deciding how to proceed.
The retained marker is evidence, not permission to erase a failed context.

Quiescence does not prove data integrity. Independent table, foreign-key, CHECK
and exact record checks, credential revocation, SecurityClock epoch rotation and
the scheduling hold still apply. Legacy points without signed integrity evidence
refuse before destructive intent. Receipt/file errors after spawn also trigger
bounded owned-child termination and reaping before returning.

The fixed deadline profiles use a separate private registry. Existing damaged
and recovery targets are not repurposed. Timings are monotonic; later success
does not attribute historical latency or clock observations. This adapter remains
an isolated synthetic qualification tool, not production hosting approval.

A09-R4 hardening records cleanup duration, decision budget, over-budget flag and
safe primary/cleanup error codes independently. Existing five-second native
control IO limits are unchanged. A delayed empty result cannot be VERIFIED after
the decision budget; late/error cleanup retains quarantine. Blocking IO, fsync or
OS reaping can return late, so this is explicit failure classification rather
than a universal three-second return promise. Never erase a historical marker
to pass tests. Explicit fresh test-marker reconciliation proves exact owned
session absence before removal.
