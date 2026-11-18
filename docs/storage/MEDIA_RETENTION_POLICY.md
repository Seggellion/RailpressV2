# Conservative alpha media retention

GCS objects use immutable fresh keys and physical deletion is unavailable in the adapter. Current-reference absence never proves backup-safe deletion. No automatic GCS garbage collection ships in this alpha.

Referenced-media purge refusal remains. An unreferenced GCS logical purge marks the asset purged, keeps ownership/descriptive/checksum fields, moves immutable bindings into additive nullable retained_objects JSON, and releases blob rows under the existing purged-state constraint. Historical DB backups still resolve their original live keys/generations. Logical removal denies application delivery; it does not erase cloud bytes.

Failed/rolled-back uploads can leave private orphan objects. Their upload-key journals remain; cleanup neither deletes nor forgets those keys. A future physical deletion tool needs positive proof that no valid retained backup requires each object and separate authorization. No such tool exists.

Disk development/test retains prior physical cleanup semantics. Persistent Disk recovery is outside the initial supported-alpha operational profile until a separate consistent DB+directory drill qualifies it. Upload tests do not prove Disk recovery.

Operators must prevent external lifecycle deletion and broad inherited delete grants. Actual versioning, soft-delete retention, lifecycle, IAM and retention-lock settings remain UNKNOWN until inspected. Noncurrent generations can be permanently removed; soft-deleted objects cannot be ordinarily read and their restoration can assign a different generation. Neither feature is assumed enabled or used as a substitute for live immutable retained objects.

For this initial contract retain every backup-required object until an approved retention policy and positive deletion proof exist. This increases costs and retains potentially personal media after logical removal; disclose it in the installation's privacy/retention policy. No GDPR exemption, zero personal data, erasure guarantee or unlimited recovery follows. Bucket/project/account/KMS catastrophe needs separate media backups if required.

The migration adds a nullable column without rewriting old rows or changing the state constraint. Older readers remain structurally compatible; actual code revert still needs separate schema/write/theme/job qualification.
