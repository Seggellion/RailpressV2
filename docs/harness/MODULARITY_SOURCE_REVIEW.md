# Modularity source review

This branch is for source review. Its commit identifies the review candidate. The existing version string is unchanged. Supported installation and updater distribution require a separately qualified release artifact.

## Core interfaces

- Extension API 1 validates package manifests, publisher purpose, signed inventories, entrypoints and dependencies before loading a trusted Rails engine. Extension routes and forms pass through Core scope, session, CSRF and authorization controls.
- Owner installation requests bind the reviewed package and site state. The native operator correlates signed results with the running web and worker. A newly installed extension remains disabled until a separate enable action. Disablement retains package data.
- The two additive Core migrations add extension lifecycle and theme-upload state. Extension migrations have scoped version and checksum tracking. Operator interruption handling preserves the original request, journal and observed schema for review.
- Theme uploads use bounded ZIP intake, private quarantine and publisher verification. Theme schema 2 adds optional presentation slots and extension dependencies. Preview and publish remain separate Owner actions. The default Dusk theme remains in Core.
- Package-aware compatibility and recovery track the signed package and manifest digests, supported schema and job ranges, and persistent references. Fresh restore checks credential invalidation and a signed withdrawal ledger before allowing affected candidates to reopen. Recovery with insufficient ledger coverage retains the privacy hold.

Core owns identity, authorization, the application shell and the package contracts. Independent engines own their domain data and workflows. Independent theme packages own their public presentations. Catalog publishing, deployment configuration and participant data belong to their respective installations.

## Local review limits

Use the guarded synthetic PostgreSQL and MySQL profiles and the native test runner. Package fixtures under test use synthetic identities and ephemeral test signers. Disk restore and module-apply command proofs cover admitted synthetic profiles. Local validation covers the recorded native checks, production-mode asset build and Chrome flows. Admitted-host reboot and independent backup-custody recovery are unverified. Accessibility statements are limited to the recorded checks.

The two compatible-release legs and interruption evidence cover synthetic operations. Review schema, job and package compatibility before any proposed code revert. Coordinate data recovery into a fresh target.
