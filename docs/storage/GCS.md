# Optional private GCS backend

Select the gcs storage backend only after configuring operator-owned project/bucket/credentials outside source. See config/storage.yml and lib/railpress/gcs for exact settings and bounded store behavior. No bucket/account is created by installation; no mandatory hosted service or private-site configuration is embedded.

The runtime uses fresh keys, create-only generation preconditions and persisted generation/size/SHA256 bindings. Delivery validates bytes and privacy permissions. Logical purge/failed-upload cleanup retain physical objects and tombstones conservatively. Keep objects needed by every valid backup; lifecycle deletion or missing/noncurrent objects can invalidate a restored database. Versioning/soft-delete alone do not satisfy live-key availability or independent disaster backup.

Separate identities: runtime create/read only; recovery read only; separately authorized operator policy/cleanup. No application delete/overwrite/bucket/IAM policy permission. Credential files require private ownership/custody outside the tree; do not paste secrets into manifests, logs or source.

Local SDK/API fixtures qualify application behavior, not a live bucket or cloud policy. Real IAM, lifecycle, versioning, soft-delete, authorization, costs and full DB/media recovery remain NOT TESTED pending an authorized isolated provider fixture. Never point synthetic tests at production buckets.
