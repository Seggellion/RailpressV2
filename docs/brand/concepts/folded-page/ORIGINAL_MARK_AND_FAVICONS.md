# Core mark and favicon contract

The folded-page-and-rails symbol is an original, wordmark-free vector with transparent cutouts and a solid#f45d63fill. The Owner approved the exact SVG SHA256919b0528d6b77f0c23bc2db3c6e1726417d59b9e0dd45722db93c32a4f4220d2 and reviewed PNG/ICO derivatives for Railpress branding and MIT public-core distribution during A02. The older supplied Railpress symbol/wordmark is excluded; this approval does not clear that older asset.

An actual built-in image-generation concept preceded the hand-authored editable SVG interpretation. The raw raster attempts had rendering artifacts and were rejected, not converted or redistributed as a claimed vector master. The production SVG consists of original paths, geometric cutouts and a mask; no third-party image, stock logo, font or supplied mark was an input. Generation logs/raw attempts/Owner response remain private engineering evidence. `ASSET_MANIFEST.json` binds all distributable bytes. The root MIT license applies to these approved source assets; no trademark exclusivity or independent legal certification is claimed.

| Asset | Intended use |
|---|---|
| railpress-mark-919b0528d6b77f0c.svg |Scalable core header/sidebar identity and favicon, intrinsic96×96viewBox |
| favicon-9344262c9cd4eab3.png |32×32RGBA favicon fallback |
| touch-icon-6e13f7b56aa206a9.png |180×180RGBA touch icon metadata; no non-Chrome device-support claim |
| favicon-da7eff0a98a3fc0a.ico |Verified16/32/48RGBA PNG entries in ICO directory |

Filenames include content hashes so long-lived static caching does not pin a changed design to the same URL. Retain old referenced assets through future releases according to the native asset-retention contract; don't overwrite a fingerprinted URL. Layout metadata declares correct sizes/types. SVG contains no scripts, links, external references, foreignObject or fonts. PNG dimensions/color type and ICO offsets/signatures are checked. Core-owned protected branding never reads public theme overlay/logo settings. Decorative header images have empty alt/aria-hidden next to accessible Railpress text. Themes may still supply their own public favicon through the existing API; otherwise the core mark is the default. This adds no theme appearance option.

Reproduce exports with `python3 scripts/brand/verify_exports.py --output /new/disposable/output`. Native build-only dependencies are Python3/PyGObject and librsvg2.58.0 as qualified locally. The script refuses existing output, validates source hashes, rasterizes only this reviewed SVG and verifies PNG/ICO bytes against the approved files. The running CMS consumes static assets and does not need an SVG decoder or PythonGI. Patched production libvips deliberately does not enable SVG uploads.

Chrome qualification verifies actual links, image loading, HTTP MIME/cache, responsive header dimensions and focus, plus icon visibility on light/dark presentation. Asset previews are not fake browser screenshots. See the exact A02result for measured scope and limitations; no other browser has been qualified.
