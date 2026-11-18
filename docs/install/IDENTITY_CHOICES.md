# Installation identity choices

The existing secure local first Owner remains mandatory and independent of public membership. It never uses Discord or open registration. SMTP/provider failure must not lock the Owner out of staff sign-in or constrained operator recovery.

After Dusk appearance, the wizard presents Membership and Verification. Choose Disabled, Email, Discord, or Email or Discord. The persisted values are disabled|email|discord|both. Both offers either independently verified method, not mandatory dual verification; email_and_discord is deliberately not a spelling alias. Default registration is closed. Selecting a method records a requested policy; a separate unchecked control explicitly enables new registration only when every selected provider is ready. Leave it closed to finish installation without provider credentials. Review and optimistic progress prevent skipped or stale approval.

Host operators configure RAILPRESS_MEMBERSHIP_CONFIG as a canonical absolute0600 JSON file owned by the application user, outside distributable source/releases. The web wizard never accepts provider credentials or tests an arbitrary host. Unconfigured status is actionable and cannot become a green success through an empty options object. Settings > Accounts allows the Owner to revisit requested policy/readiness and explicit activation after setup. Changing it revokes Member sessions/pending proofs, preserving staff sessions.

Example structure (placeholders only; verification flags must stay false until actual operator qualification):

```json
{
  "email": {
    "verified": false,
    "sender": "membership@example.invalid",
    "host": "smtp.example.invalid",
    "port": 587,
    "username": "<host-owned-username>",
    "password": "<host-owned-secret>"
  },
  "discord": {
    "verified": false,
    "pkce_s256_verified": false,
    "client_id": "<registered-application-id>",
    "client_secret": "<host-owned-secret>",
    "callback": "https://your-canonical-origin.invalid/login/members/discord/callback"
  }
}
```

Email supports required STARTTLS587 or implicitTLS465 with peer verification and bounded delivery. Test sender/domain/SMTP/inbox/late-bounce/recovery behavior using separately authorized provider credentials; a successful SMTP submission is not a completed account. Membership email delivery is independent of existing staff password-recovery mail configuration; qualify both before deployment. Real internationalized-mail delivery is provider-dependent and not implied by local Unicode normalization.

Discord requires a confidential registered application, exact canonical HTTPS callback and verified S256 behavior. Request identify and email only when email is required; no bot/guild scopes. Current providers/readiness are visible before explicit registration enablement. Synthetic verification is visibly labelled synthetic, never live verified. A missing method stays unavailable; an explicitly selected alternative can be used without changing policy.

CLI install asks the same nonsensitive policy questions and defaults disabled/closed. Private progress retains no SMTP/client secret, and final review reports requested policy plus actual registration state. Existing in-progress older wizards must revisit/review the newly required Membership step; no implicit open-registration upgrade. Existing installed sites receive disabled/closed defaults through additive schema12 migration. Content exports cannot activate member registration at another site.

Native schema12 fresh diagnostics do not prove a strict-newer compatible core update/revert from schema11. Those native release/clock gates remain open. Actual live mail, Discord callback/PKCE/revocation, hosting/privacy/log retention and M17 activation require separate Owner authorization and proof. No real SMTP send or Discord API request is part of the local amendment fixture.
