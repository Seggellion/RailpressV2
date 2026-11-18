# Railpress 2.0 versions

Railpress Core uses Semantic Versioning. `lib/railpress/product.json` is the sole running product-version authority: **2.0.0-alpha.1**, channel **alpha**. Product constants, native `bin/railpress --version`, doctor, installer environment and dashboard derive from it. Release packages must contain the same identity as their signed manifest. A main-branch commit is source, never an installation update.

Alpha previews advance alpha.2, alpha.3, etc.; prerelease numeric identifiers compare numerically. Stable 2.0.0 requires separate stable qualification and signing approval. Stable checks exclude prereleases; alpha checks accept alpha and stable releases. Legacy development metadata remains supported for historical synthetic fixtures only, never a public alpha feed candidate.

Dusk is independently versioned at **1.3.0** in `lib/railpress/dusk.json`; Theme API remains **1**. Core schema14, jobs1, configuration2 and SecurityClock2 are compatibility contracts, not product versions. Every signed update records runtime ranges, both database ranges, readable/writable schema/jobs ranges, approved theme identities, configuration, assets and predecessor constraints. Do not relabel historical 0.1 artifacts or evidence.

Public source availability is not M16 certification. No production-trusted release or stable artifact is authorized by publishing this source.
