# Instruction discovery and provider boundaries

Canonical contract: AGENTS.md, Harness v1. CLAUDE.md contains @AGENTS.md and no
separate policy. No .grok configuration, hook, MCP server, provider SDK, API key,
automatic account setup or remote model execution is installed by the Harness.

| Client | Vendor-documented entrypoint | Actual local qualification |
|---|---|---|
| Codex CLI | AGENTS files discovered along root-to-working-directory chain; nearer overrides and user config can affect loading |0.154.0 limited synthetic instruction/plan probe PASS: isolated home, read-only mode, execution/integrations disabled, canonical root heading and delegation policy observed; no tool actions. This does not qualify implementation, database or general agent safety |
| Claude Code | CLAUDE import resolves relative to its file; recent clients also support AGENTS, subject to settings |2.1.318 text-only plan observed, but canonical instructions were not auto-loaded in the restricted first probe. Packet-confined Read follow-up failed with expired/unrefreshable OAuth. Canonical load/import and feature implementation NOT TESTED; no login/credential repair attempted |
| Grok Build | Repository AGENTS and compatible CLAUDE names discovered by directory; grok inspect reports loaded rules |No installed executable discovered; NOT TESTED; no automatic install or compatibility claim |
| Human/native CLI | Ruby stdlib CLI and explicit guarded native commands |No provider account/key required; exact workflow and regression evidence are recorded in the current milestone result |

Sources checked for A07: [Codex instructions](https://learn.chatgpt.com/docs/agent-configuration/agents-md),
[Claude memory/imports](https://code.claude.com/docs/en/memory),
[Grok project rules](https://docs.x.ai/build/features/project-rules).
These support file-discovery conventions, not a tested claim about the current
account/session. An instruction file can be overridden by external client policy;
inspect actual loaded context before work. Do not duplicate policy into gateways.

The Owner explicitly approved the five-document synthetic packet for these probes.
No CMS implementation, private site, Git history or credential payload was sent.
Initial diagnostics and follow-ups are separate records; a strict title check in
the first Codex parser did not negate its observed policy quotation. The follow-up
also met the exact title check. Claude's documented import is not promoted to PASS
from documentation or from its text-only response. Grok remains unavailable. A07
therefore cannot claim all three clients are tested compatible; A08/A09 must retain
these provider gates. The ordinary human/CLI workflow has no provider dependency.

Remote tools may send prompts, file/tool output and source according to provider
settings and account terms. Approve the precise data scope first; use a synthetic
packet for compatibility testing. Never send credentials/private site/history or
production data. Do not change global permissions/security settings or suppress
provider checks. The harness cannot sandbox independent agent processes; the
shared policy plus fixed CLI guards are not a claim that all three models cannot
misbehave. Missing live provider proof limits qualification and release claims.
