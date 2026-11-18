# Dusk paired semantic colors

Dusk1.2.0 retains editorial typography, spacing, breakpoints, semantic blocks and original CSS geometry. Public body tokens inherit into every theme component, separately from protected core styles.

| Role | Light | Dark |
|---|---|---|
| Canvas / inverse control text | #fbfaf7 | #141e27 |
| Primary text / filled control | #202d38 | #f3eee5 |
| Supporting text | #52616b | #bac7cf |
| Afterglow accent / focus / links | #a13f24 | #ffb58e |
| Woodland accent | #345c43 | #a7d8af |
| Slate accent | #375c7d | #a9cfee |
| Afterglow panel | #f0e9df | #24333e |
| Woodland panel | #e7ede5 | #24392f |
| Slate panel | #e6edf3 | #253747 |
| Decorative separator | #c9c6be | #536572 |
| Input / image backing | #ffffff | #1c2a35 |
| Input boundary | #52616b | #a5b8c4 |

Separators convey no interactive state; inputs use stronger boundaries. Focus is3px accent,4px offset; skip/main focus use effective tokens. Buttons invert primary/canvas and use accent hover. Links retain underlines/weight and increase hover thickness. Search labels remain visible; placeholders use opaque muted text. Disabled controls retain native disabled semantics; invalid inputs use2px boundaries. Selection inverts text/canvas. Code, callouts, FAQ, tables, cards, disclosures, pagination, missing media, notices and empty/404 states share the tokens.

The default horizon mark adapts through ink/accent without another image or wordmark. Uploaded pixels/alpha remain intact; no global inversion/dimming/filter. Owner preview must assess custom image contrast and supply an appropriate asset where its own foreground is unreadable. The cleared red core emblem/favicon is unchanged. User-upload rights are never inferred.

All desktop/mobile layout, native disclosure and keyboard behavior remain. Reduced motion disables animation/transitions; appearance changes never animate. Forced colors retain system focus/boundary rules but actual-device qualification is separate.

WCAG2.2AA targets: normal text4.5:1, qualifying large text3:1, meaningful UI/focus3:1. Measure primary/muted/accent against canvas/panel/input and inverse controls. Decorative separators/art facets are not text. Computed-color measurements and actual Chrome findings belong to A03 evidence; no full conformance, screen-reader or other-browser claim follows from automated contrast.
