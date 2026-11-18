# Railpress architecture for feature work

AGENTS.md is the canonical contract. This map explains the existing authorities;
the Harness creates development files, not new authority.

| Area | Existing owners | Invariant / review surface |
|---|---|---|
| First installation | Setup::Complete, Installation services, BootstrapState | Local first Owner, claimed one-time setup, no implicit schema preparation on web boot |
| Staff | Identity services and direct capabilities | Last Owner protected; authenticate and authorize each endpoint, not just sidebar links |
| Members | Membership services; docs/auth | disabled/email/discord/both are visitor verification policies; never grant staff from provider claims |
| Editorial | Editorial::Workflow, Previews, Terms; ContentRevision | Published immutable snapshot differs from draft; scoped expiring previews; optimistic conflicts; due worker |
| Media/blocks | MediaLibrary, ContentBlocks | Validate actual bytes/dimensions/budgets; approved serializer; private references never become public |
| Navigation | Navigation::Mutation, Tree, Destinations | One transactional tree authority; typed canonical links, same-menu parents, bounded depth, revisions |
| SEO/public routes | Seo::Policy, RouteRegistry, SiteOrigin | Configured origin; canonical/status/robots/schema/sitemap agree; reserved protected families; SSRF-bounded diagnostics |
| Public rendering | Themes::Manager/Context/Selection; Theme API v1 | Trusted immutable package and request-local presenters; private overlays/previews; core owns protected views/head |
| Privacy | Privacy::Policy, anonymous middleware | No nonessential anonymous state/automatic remote embeds; preserve essential authenticated security |
| Time | Railpress::SecurityClock, SecurityDeadline | Monotonic/domain-bound security authority, revoke/hold on unsupported changes; wall-clock observations are not trusted UTC |
| Portability | Portability services, Railpress::SiteArchive | Approved versioned nonsensitive data; stage/conflict/reversal; exclude account/host secrets |
| Native operations | Releases and NativeHost | Operator authority outside web; signed synthetic fixtures are not production trust; code revert differs from restore |
| Developer Harness | Railpress::Harness::CLI | Explicit review, fixed native command vectors, synthetic admission, no provider/network/Git mutation verbs |

Read relevant source and tests before proposing changes; do not infer a service's
arguments from this overview. Additive portable expand/backfill/contract migrations
need both-engine proof and release compatibility review. MySQL DDL is not atomic.
PostgreSQL native SQL restore uses a transaction; media/config and SQL together
are still a multi-step operation behind maintenance and explicit recovery.

Dusk assets and overlays are independent of protected admin design. Generated
art/emblem licenses do not grant the older wordmark or private official-site
content. No feature depends on a private website checkout or private playbook.
See docs/product/FEATURE_MATRIX.md for scoped implementation/release limitations.
