# Harness qualification matrix

| Gate | Required proof |
|---|---|
| Read-only entrypoints | Source/Git/private-state before/after doctor, plan and report; no account/key/provider/DB dependency |
| Review binding | Exact file payloads, canonical policy, source and root digest; stale/unreviewed/unknown flags refused |
| Filesystem safety | Traversal/shell/Unicode/reserved names, symlink parents/state, collisions, private modes, held locks, interruption/resume, unchanged repeat, edited file preservation |
| Secret/authority safety | Accidental source secret redaction, connection/production/Git-env override rejection, no push/commit/deploy/reset verbs, no privilege/schema/route installation |
| Real example | Empty/Unicode/word boundaries, rate validation, size/encoding limits, exact ceiling arithmetic; unmounted controller and commented route |
| PostgreSQL16 | Exact synthetic DB/role/instance/root, example plus full tests/eager loading, empty migration and independent schema load, real constraints |
| MySQL8.4 | Independent same workflow, actual DDL/constraints; never infer from PG success |
| Quality | Production assets reproducibility, eager loading/no DB boot, native TLS boot/restart, lint, Brakeman, current advisory/secret/license audit |
| Provider workflows | Actual named client/version, instruction paths, no unauthorized tools/source transfer; unavailable or unapproved = NOT TESTED |
| Preservation | Original/private source and indexes, history/refs/staging, no public/private leakage; unchanged evidence and verified recovery snapshot |

Chrome checklist for any eventual UI integration:360/768/1440CSSpx,200%zoom,
keyboard/focus, reduced motion, actual storage/network/JS/cookie/redirect and
accessibility. The Harness adds no mounted browser surface. Existing A05/A06
Chrome and assistive-technology gates remain NOT TESTED where not executed.
HTTP/static inspection is not an equivalent result; no other browser is claimed.

Use independent test counts and actual source snapshots. Prior tests, a current
scan with no findings or a successful example are not broad security/release/host
certification. Historical clock/worker, native recovery and M05/M08 conditions
remain open until their exact qualification gates execute. A08/A09 and launch
are separate authorizations.
