# Railpress 2.0 versions

Railpress Core uses Semantic Versioning. `lib/railpress/product.json` is the sole running product-version authority. The SEO update source identifies **2.0.0-alpha.3**, channel **alpha**. Product constants, native `bin/railpress --version`, doctor, installer environment and dashboard derive from it. Release packages must contain the same identity as their signed manifest. A main-branch commit is source, never an installation update.

Alpha previews advance alpha.2, alpha.3, etc.; prerelease numeric identifiers compare numerically. Stable 2.0.0 requires separate stable qualification and signing approval. Stable checks exclude prereleases; alpha checks accept alpha and stable releases. Legacy development metadata remains supported for historical synthetic fixtures only, never a public alpha feed candidate.

Dusk is independently versioned at **1.4.0** in `lib/railpress/dusk.json`. This redesign preserves Theme API **1** and existing option meanings. Core schema 14, jobs 1, configuration 2 and SecurityClock 2 are compatibility contracts. Every signed update records runtime ranges, both database ranges, readable/writable schema/jobs ranges, approved theme identities, configuration, assets and predecessor constraints. Historical artifacts retain their original version and evidence.

Public source availability is not M16 certification. No production-trusted release or stable artifact is authorized by publishing this source.
