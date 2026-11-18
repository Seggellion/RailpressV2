# Harmless example: plain-text reading time

Plan/scaffold reading_time in a disposable developer checkout as described in
FEATURE_PLAYBOOK.md. The proposed module is Railpress::Extensions::ReadingTime;
minutes(text, words_per_minute:200) returns the ceiling of recognized word count
divided by a validated integer rate. Empty text returns0. It accepts bounded valid
UTF-8 plain text. It is an estimate for word-separated prose, not a language-aware
segmentation or rich-HTML sanitizer. Use an existing approved plain-text presenter
if later integrating editorial content; never pass private data to an API.

Generated tests exercise0/200/201/401word boundaries, Unicode/punctuation, custom
rate and invalid rates/encoding/oversize. The controller returns404; its view and
commented route proposal are intentionally unreachable. No menu, role, migration,
theme or published content changes. Inspect the exact output plan before writing.

This example is exercised on the isolated native database engines through the
same verify command a human uses. Generated files belong only to the disposable
example worktree; they are not silently integrated into core. Final exact counts,
source digests and failures belong to docs/evidence/A07/RESULT.md in the private
qualification workspace; that private evidence is not required to run the public
developer kit. A successful example is not complete CMS/browser qualification.
