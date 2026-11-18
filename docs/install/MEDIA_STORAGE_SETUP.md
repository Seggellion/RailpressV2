# Media Storage in guided setup

Google Cloud Storage with ADC / Workload Identity is the recommended production choice. Disk works without a Google Cloud account for development/testing and an independently verified persistent native volume. Neither selecting a backend nor a successful local check qualifies production recovery.

The protected flow is Environment → Database → **Media Storage** → Identity → Owner → Dusk → Membership → Review. Claim setup using the operator's one-time secret. Database/schema preparation remains explicit. Media Storage asks only for a backend, project ID, existing bucket, optional object prefix and authentication preference. It never accepts cloud keys, JSON credentials, tokens, endpoints or host file paths.

Choose GCS/ADC first. Select the appropriate ADC environment: automatic discovery, attached workload identity, federation on an external native host, explicit native ADC or development-only user ADC. Use the operator-managed service-account file fallback only when explicitly required and selected on both host and installer. A file's existence is not token, IAM or upload proof. Missing ADC never switches to a key automatically.

**Verify Storage Configuration** saves a validated choice. If it differs from the running adapter, setup stays on this step with ACTION REQUIRED. Give the nonsecret selection to the operator. They apply it to both web and worker services, restart those owned services, then you resume. The browser cannot edit environment files or restart processes. The selected choice survives an interrupted claim; a new claim removes the previous temporary Owner verifier and requires review again.

| Status | Meaning |
|---|---|
| CONFIGURED | Local settings/source/prerequisites match the running adapter; provider operations are not established. |
| VERIFIED | A specifically named operation was observed, such as the fresh Disk sentinel. Never a blanket production claim. |
| ACTION REQUIRED | Missing/invalid settings, unsafe permissions, mismatch, stale approval or operator handoff. |
| UNAVAILABLE | A required capability cannot currently be used. No silent substitute. |
| UNSUPPORTED | The requested backend/credential/operation is outside the declared contract. |
| NOT TESTED | The check has not been executed with appropriate authority/environment. |

For Disk, review the displayed directory and permission result. The installer verifies one newly created sentinel only, then removes that sentinel. It does not inspect or delete existing media. Permissions and free space do not prove a durable volume. Do not store valuable media on an unknown/ephemeral filesystem. Persistent Disk disaster recovery remains unqualified.

For GCS, local verification loads the existing adapter, checks typed settings, credential-source visibility and the private processing directory. It makes **no metadata, token or bucket request**. Actual private-bucket/IAM/upload/read/generation/checksum/retention verification needs separately approved disposable objects and credentials. No bucket creation, IAM change, billing or real-provider operation is authorized by setup.

After setup, start the configured worker and request Site Readiness. A real queue worker reports its nonsecret configuration with a boot-bound lifetime. Absent, stale or different reports do not establish agreement. Agreement is not cloud-principal or IAM proof. Provider status remains NOT TESTED until separately qualified.

Storage intent is locked at installation. A changed backend/project/bucket/prefix/authentication selection does not move an existing library; media operations refuse configuration drift. Existing pre-R8 installations are explicitly unbound and require operator review. Never use setup to migrate them. Keep original SQL/media and seek a separately qualified migration/recovery operation.

See [GCS operator guide](../storage/GCS_INSTALLATION_GUIDE.md), [typed contract](../storage/CONFIGURATION_CONTRACT.md) and [state-machine amendment](STORAGE_STATE_MACHINE.md). The equivalent CLI asks the same nonsecret questions and stops safely for a handoff.
