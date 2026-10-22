# NEEDS VALIDATION — dhc-dashboard `apps/phoenix` run-1

Nine unresolved leads. Each has a complete source trace and evidence; each is
blocked on exactly the facts named below. **No severity is assigned and none is
a confirmed vulnerability.** Validation plans are owner-observed or bounded
local fixtures; none sends audit traffic to production or a live provider.

---

## 1. Public external checkout forwards a caller-selected return destination

- **Fingerprint**: `workshops.external_checkout.return_url`
- **Trace**: `apps/phoenix/lib/dhc_web/router.ex:364` (public route) →
  `apps/phoenix/lib/dhc_web/controllers/workshops_controller.ex:221` →
  `apps/phoenix/lib/dhc/workshops/payment_commands.ex:287` (placeholder check
  only) → `apps/phoenix/lib/dhc/workshops/payment_commands.ex:1470`
  (`return_url` in the Checkout Session body) →
  `apps/phoenix/lib/dhc/workshops/stripe_adapter/live.ex:35` (sent to Stripe).
  Two wave-1 hunters independently converged on this root cause.
- **Blocker**: Stripe's handling of an unrelated `return_url` host in this
  embedded Checkout flow — whether it accepts it and navigates the payer there
  after payment — is provider behavior not established by repository source or
  the fake-boundary contract test.
- **Validation (deployment, owner-observed)**: an authorized Stripe account
  owner inspects the effective API version and applicable embedded Checkout
  policy/configuration, **without creating a session or making API calls**, and
  determines whether an unrelated HTTPS `return_url` host is accepted and
  followed. If policy does not settle it, retain the blocker. If confirmed,
  bind `returnUrl` to the configured app origin and add regression coverage for
  foreign hosts/schemes (the billing-portal flow at `membership.ex` already
  demonstrates the same-origin policy).

## 2. Member workshop payment accepts an unbound Stripe Customer

- **Fingerprint**: `workshops.member-payment.customer-id-binding`
- **Trace**: `apps/phoenix/lib/dhc_web/router.ex:507` (authenticated) →
  `apps/phoenix/lib/dhc_web/controllers/workshops_controller.ex:165` (principal
  from session; params passed through) → `apps/phoenix/lib/dhc/workshops.ex:352`
  (caller `customerId`) → `apps/phoenix/lib/dhc/workshops/payment_commands.ex:260,1445`
  → `apps/phoenix/lib/dhc/workshops/stripe_adapter/live.ex:25` (Stripe
  `customer` field; metadata `user_id` from the attempt). Completion
  (`payment_commands.ex:1526`) checks status/metadata but not Customer binding.
- **Blockers**: (a) whether a PaymentIntent attached to another Customer, in
  this client-secret + Stripe.js Payment Element flow, exposes or permits that
  Customer's saved payment methods; (b) whether an ordinary member can
  realistically obtain another member's Customer ID (`/members/me` exposes only
  the caller's own).
- **Validation (deployment, owner-observed)**: the Stripe integration owner
  reviews existing authorized test-mode observations/configuration (synthetic
  Customers only, no new audit requests) for cross-Customer PaymentIntent
  behavior; the identity/API owner reviews member-facing routes and identity
  sources for any Customer-ID exposure path. If both resolve adversely, the
  smallest source fix is deriving the Customer server-side from the member's
  profile (or verifying ownership) in `create_member_payment_intent/3`.

## 3. Concurrent membership deactivation may defeat last-editor preservation

- **Fingerprint**: `auth.roles.last-active-editor-race`
- **Trace**: `apps/phoenix/lib/dhc_web/controllers/member_roles_controller.ex:14`
  → `apps/phoenix/lib/dhc/auth/roles.ex:41,79,83` (advisory lock; editor count
  without locking other editors' profiles) vs
  `apps/phoenix/lib/dhc/auth.ex:624` (`apply_member_access/2` locks only the
  profiles it deactivates; no shared lock; reached by Stripe sync via
  `apps/phoenix/lib/dhc/stripe_sync/repository.ex:85`).
- **Blocker**: the concurrent-commit interleaving (self-demotion passing its
  guard while the other editor's deactivation commits) has not been observed
  against PostgreSQL; the audit sandbox excluded DB-backed execution.
- **Validation (local, bounded)**: in an isolated PostgreSQL test environment,
  two active editors; a test-only barrier pauses A's role update after the
  editor count sees B; B is deactivated on a second connection and commits; A
  commits. Assert the active-editor set cannot become empty. If confirmed, the
  fix is taking the role-editor advisory lock (or locking editor profiles) in
  `apply_member_access/2`, or re-checking the editor count under those locks.

## 4. Current-device logout may leave its socket credential and established socket active

- **Fingerprint**: `dhc.auth.logout.does-not-revoke-socket-tokens`
- **Trace**: `apps/phoenix/lib/dhc_web/controllers/auth_session_controller.ex:345`
  (socket-token exchange) and `:364` (logout) → `apps/phoenix/lib/dhc/auth.ex:581`
  (deletes only `context=session`) → `apps/phoenix/lib/dhc/auth/principal_token.ex:187`
  (socket verification independent, 60 s window) →
  `apps/phoenix/lib/dhc_web/channels/user_socket.ex:78` (init-time recheck only)
  → `apps/phoenix/lib/dhc_web/channels/notification_channel.ex:79` (empty-payload
  events). Unlike access-loss (`auth.ex:645,657`), logout neither deletes socket
  rows nor broadcasts a disconnect.
- **Blocker**: post-logout socket-token acceptance and event delivery on an
  established socket need a DB + PubSub fixture; the sandboxed query-shape check
  (promoted artifact `agents/w3-relogin/artifacts/check-01.txt`) confirms the
  independent query shapes but not the boundary result.
- **Validation (local, bounded)**: isolated Phoenix test fixture — create
  principal/session, exchange a socket token, establish a socket, join
  `notifications:self`, call `DELETE /api/auth/session`; assert the session is
  rejected, and observe whether the socket token still authenticates within 60 s
  and whether the open socket receives a subsequent empty `notification_created`.
  Impact is bounded: the channel payload is empty and HTTP refetch stays gated;
  the fix is binding socket credentials (and established sockets) to their
  originating session and revoking/disconnecting those on current-device logout.

## 5. Public invitation verification exposes a DOB oracle without application throttling

- **Fingerprint**: `invitations.verify_credentials.dob-oracle`
- **Trace**: `apps/phoenix/lib/dhc_web/router.ex:354` (public `:api` only) →
  `apps/phoenix/lib/dhc_web/controllers/invitations_controller.ex:40` →
  `apps/phoenix/lib/dhc/onboarding.ex:35` →
  `apps/phoenix/lib/dhc/invitations.ex:96,546` (exact DOB match among the
  constraints) → `apps/phoenix/lib/dhc_web/controllers/invitations_http.ex:18`
  (422) vs `invitations_json.ex:24` (200 `verified:true`).
- **Blocker**: whether the deployed ingress applies an effective rate limit to
  `POST /api/invitations/:id/verify` (no application-level limiter exists on
  the route). The endpoint returns no bearer material; the exposed fact is DOB
  confirmation for a known invitation ID + email.
- **Validation (deployment)**: the owner inspects the effective ingress/proxy
  policy (CDN/WAF/edge) for this route — whether a limit applies and how it is
  keyed. Optional staged confirmation with a seeded dummy invitation and a
  small approved request sequence, non-production only. If unthrottled, the
  smallest fix is reusing the `MagicLinkRateLimit` plug pattern for this route
  (the codebase already has the machinery).

## 6. The magic-link IP limiter relies on Fly to protect its client-IP fallback

- **Fingerprint**: `DhcWeb.Plugs.ClientIp.fly-client-ip-fallback`
- **Trace**: `apps/phoenix/lib/dhc_web/router.ex:668` (public magic-link) →
  `apps/phoenix/lib/dhc_web/plugs/client_ip.ex:35` (`fly-client-ip` accepted
  without a secret check; documented Fly-only reachability + overwrite
  assumptions at `:18`) → `apps/phoenix/lib/dhc_web/plugs/magic_link_rate_limit.ex:96,127`
  (IP quota key).
- **Blocker**: whether every deployed route to the Phoenix process terminates at
  Fly's edge, and whether the edge overwrites caller-supplied `fly-client-ip`
  on all active routes. Source comments state the assumption; deployment facts
  are not in the repository.
- **Validation (deployment, owner-observed)**: the owner inspects the effective
  Fly service/listener and network attachments, and the edge's header behavior
  for caller-supplied `fly-client-ip`. No live probing. If any path bypasses
  Fly, remove the fallback (the moduledoc already says so) or key the limiter
  on the secret-protected header only.

## 7. Optional forwarding secret can collapse the magic-link IP quota onto shared egress

- **Fingerprint**: `MagicLinkRateLimit:ClientIp:forwarded-address-fallback`
- **Trace**: `apps/phoenix/lib/dhc_web/router.ex:668` →
  `apps/phoenix/lib/dhc_web/plugs/magic_link_rate_limit.ex:54,77` (IP window
  checked before email window; generic 200 on over-limit) ←
  `apps/phoenix/lib/dhc_web/plugs/client_ip.ex:35,48` ←
  `apps/phoenix/config/runtime.exs:106,111` (optional
  `TRUSTED_FORWARDING_SECRET`). Out-of-scope context:
  `apps/web/src/lib/server/api-client.ts:98` (web sends headers only when its
  secret + client address exist), `apps/web/wrangler.jsonc:37` (no secret in
  vars), `fnox.toml:39` (Phoenix secret is a 1Password reference;
  `Dockerfile:92,114` fail-closed on missing fnox items).
- **Blockers**: (a) deployed Worker secret presence/equality with Phoenix's
  value; (b) the fallback IP Phoenix attributes to server-side requests (a
  shared egress address would make the 10/hour IP window shared across all
  users of the SvelteKit path — a self-DoS-shaped availability risk, not a
  bypass).
- **Validation (deployment, owner-observed)**: without disclosing either
  secret or generating requests, the owner verifies the Worker secret is
  nonblank and equal to Phoenix's effective value; separately, from existing
  operational telemetry and network configuration only, establishes the
  `fly-client-ip`/`remote_ip` Phoenix observes for Worker-originated requests
  and whether distinct clients share an IP quota key. Fix direction: a web-side
  startup guard for the secret, or a Phoenix-side quota keyed per email only.

## 8. Receiving downloads accept unrestricted HTTPS destinations

- **Fingerprint**: `dhc.resend.receiving.download-unrestricted-https`
- **Trace**: `apps/phoenix/lib/dhc_web/controllers/resend_webhooks_controller.ex:32`
  (Svix-verified webhook; `:91-99` gated on the feature flag) →
  `apps/phoenix/lib/dhc/beginners_workshops/intake_replies.ex:155,177`
  (records ID; queues ID-only job) →
  `apps/phoenix/lib/dhc/beginners_workshops/workers/reply_worker.ex:21`
  (**runs the forward without re-checking `enabled?`**) →
  `intake_replies.ex:244,339` → `apps/phoenix/lib/dhc/resend/receiving.ex:62,65`
  (any HTTPS+host URL to Req; no allowlist, no redirect restriction). Default
  config (`config.exs:77`) has the feature off.
- **Blockers**: (a) the effective deployed `IntakeReplies.enabled?` value and
  whether any ReplyWorker jobs are queued/executing/retryable (the worker does
  not re-check the switch); (b) Resend's guarantee that attachment/raw download
  URLs are provider-controlled; (c) deployed egress policy for
  private/loopback/link-local destinations and redirects.
- **Validation (deployment, owner-observed)**: the owner inspects the deployed
  feature setting and job state; if any forwarding job can execute, reviews
  Resend's URL-provenance guarantee and the worker's egress policy. No test
  traffic. Fix direction: an allowlist (the Web Push endpoint module is the
  in-repo precedent), redirect-pinning, and a worker-side `enabled?` check.

## 9. Public Waitlist registration may reveal email presence through response timing

- **Fingerprint**: `waitlist.create_entry.email-timing-oracle`
- **Trace**: `apps/phoenix/lib/dhc_web/router.ex:356` (public `:api` only) →
  `apps/phoenix/lib/dhc_web/controllers/waitlist_controller.ex:67,70` (identical
  `received=true` for refusal and success) →
  `apps/phoenix/lib/dhc/waitlist.ex:708,714,720` (locked lookup; insert path)
  → `apps/phoenix/lib/dhc/invitations/email_refusals.ex:35` (Principal check
  short-circuits the Invitation check).
- **Blockers**: (a) whether the state-dependent database work produces
  remotely distinguishable latency distributions (needs a running
  Phoenix/PostgreSQL fixture — excluded by the run's boundary); (b) whether the
  deployed ingress limits repeated probes on this route.
- **Validation (local, bounded)**: isolated disposable environment; seed one
  synthetic record per class (waitlist email, principal email, pending-invitation
  email); one warm-up per class; then 10 randomized blocks of identical valid
  registrations (one per seeded email + one fresh unique synthetic email per
  block; 44 requests total); compare per-class latency while confirming
  identical responses. Synthetic data only; discard the environment.
  (Deployment): owner inspects effective ingress limits for the route.

---

**Method note**: these nine leads are the residual candidate set after three
hunting waves, per-wave and final-clean coverage critics, independent Phase-3
verification (including one correct demotion of a proposed-confirmed candidate),
and fresh Phase-5 record verification. The one claim that a fresh re-hunt
disproved is recorded as `rejected` in `findings.json`
(`inventory.container-detail-item-location-disclosure`: documented ALE-106
member-readable container detail, not a missing authorization control).
