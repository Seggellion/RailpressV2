# Candidate alpha recovery support

This proposed0.1.0-alpha.1 contract is not production support or release authorization. M16 must accept the exact final evidence, host/artifact and support statement before M17.

| Operation | Candidate scope |
|---|---|
| Disk | Existing development/test; persistent Disk recovery unqualified |
| Private GCS | Optional adapter implemented; actual provider/bucket/IAM/policy qualification required |
| DB recovery | Operator-managed load into distinct empty native PG16/MySQL8.4 target, full verification/source preservation; synthetic admission currently executable |
| Media gate | Read-only retained live key/generation/size/actual SHA256 verification; no copying/repair |
| Cutover | Separate maintenance-window operational qualification/authorization; no automatic promotion |
| Loss/outage | No unverified consistency, RPO/RTO or availability guarantee |

Unsupported in this new contract: populated in-place restore; automatic restoration of deleted/noncurrent GCS objects; automated DR orchestration/promotion/failover; zero-downtime recovery; persistent Disk recovery without separate proof; bucket/project/account/KMS catastrophe without an independent media backup. The older NativeHost synthetic in-place implementation/evidence remains preserved; its existence is not current alpha operational qualification.

Objects must stay private, immutable, live/readable and retained for every valid backup. Physical GC is deferred. Actual lifecycle/IAM/soft-delete/versioning is not inferred. Source/private-site isolation, stable config/key custody, host UTC/security authority and accepted loss/outage remain gates. M15 portability is not a backup.

M12 implementation7 and M16 execute1/5/8/D02 retain real backup/restore proof under this narrower scope. Separate update/revert/availability/current predecessor/release/private-site pin, valid-TLS Chrome/AT, live SMTP/Discord, privacy/logging, Harness clients, source/history/rights/dependency/claims/CI/signing/editorial and per-action Owner gates remain. Historical M05/M08 and earlier SQL failures keep unknown causes. A successful narrower path does not explain them.
