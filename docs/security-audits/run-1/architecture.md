# Architecture summary — dhc-dashboard apps/phoenix security audit, run-1

**Target**: `apps/phoenix` at `4de8bf54` (GitButler workspace commit). The 3 dirty paths are outside the target; the Phoenix subtree is clean. Scoped `standard` run: `apps/phoenix` only. `apps/web`, `packages/`, repo-root CI/mise/fly.toml are out of scope.

## Product, principals, protected resources

Dublin HEMA Club member-dashboard backend: a JSON API (Phoenix 1.8, Ecto/Postgres, Oban, Bandit) behind a SvelteKit frontend, deployed as a Fly.io release. Domains: members/roles, membership subscriptions + Stripe billing, paid workshops + refunds, beginners'-workshop intake (seat holds, payments, waitlist, carried fees), equipment inventory + loans, announcements (member/training/workshop via email + Discord), notifications (incl. RFC 8291 Web Push), club email (Resend).

Principals, low → high trust:
1. **Anonymous public**: `POST /api/auth/magic-link` (rate-limited) and `/verify`; Discord OAuth `/api/auth/discord(+/callback)`; `GET /api/invitations/:id`, `POST /api/invitations/:id/verify` (email + DOB); invitation-acceptance ops under `/api/onboarding/invitation-acceptance*` authenticated by the signed `_dhc_onboarding_acceptance` handle cookie (15-min, path-scoped); `GET/POST /api/waitlist/(status|entries)`; `POST /api/webhooks/stripe` and `/resend` (HMAC-authenticated); `GET/POST /api/workshops/:id/external-registration*` (public checkout, `returnUrl`); `/api/beginners/intake/:token*` (path token is the only credential; redaction pipeline); `/api/health`, `/api/options`.
2. **Active members**: `_dhc_session` cookie carries a 32-byte bearer token stored only as SHA-256; session re-evaluates activity + roles per request and emits a `capabilities` projection. Any active member: profile read/update (owner-scoped via `MemberAccess`, non-owner 404), pause/resume, own notifications, member inventory catalog + own loans, socket-token exchange.
3. **Capability-gated staff**: one registry `Dhc.Auth.Capabilities` maps roles (president, admin, committee_coordinator, treasurer, beginners_coordinator, quartermaster, workshop_coordinator, training roles) to capabilities; router pipelines are named after capabilities (`RequireSession` refuses owner/assignment-scoped capabilities at the pipeline, controllers enforce those).
4. **Assignment-scoped workshop staff**: `beginners.workshops.run` granted by workshop Staff rows; denial conceals as 404.
5. **Provider/system actors**: Stripe + Resend webhooks (signature-verified, raw body), Oban workers (`:system` actor allowlists in `Dhc.BeginnersWorkshops.Commands`), cron sweeps; outbound only: Stripe API, Resend, TypeSafe/Jev classifier, Discord.

Protected resources: member PII (DOB, emails), hashed credential tokens, Stripe money (subscriptions, payments, refunds), Discord identity bindings, waitlist persons (3-month retention purge/anonymisation), session integrity.

## Controls, entry surfaces, key paths

Strongest source-visible controls: `RequireSession` (session + non-resource capability; signed cookie → DB token → live projection); constant-time comparisons on secrets; Stripe webhook HMAC-SHA256 over raw body with constant-time compare and a 300 s lower-bound timestamp check (no upper bound — recon lead); Resend/Svix ±5 min absolute window; `Dhc.Onboarding.Acceptance.Locked` advisory→row lock graph with opaque handle and closed safe views; `Dhc.Workshops.PaymentCommands`, `Dhc.Inventory.AvailabilityCommands`, `Dhc.BeginnersWorkshops.Commands.Protocol` — single-transaction command boundaries with declared lock orders, Stripe only between transactions, idempotency keys; Web Push endpoint host allowlist re-checked at send with redirects disabled; sealed email variables (Oban args); intake-link log/Sentry redaction (`IntakeLinkPrivacy`); non-enumerating magic link (3/15 min per email, 10/h per IP via `ClientIp`); E2E-harness routes compile-gated (`:e2e_harness`), key-checked.

Entry surfaces beyond HTTP: Oban job args (durable, DB-resident), PubSub (local), WebSocket `/socket` (`notifications:*` only, 60 s socket token revalidated), cron (Stripe sync, sweeps, retention), operator CLI (`mix dhc.waitlist.import`, `dhc.discord.assignments`, `dhc.intake_replies.eval` — caller-chosen file paths, no size caps visible).

Notable egress: `returnUrl` (public external checkout; authenticated billing portal), coupon candidates, Resend attachment downloads (`Receiving.download/1` accepts any HTTPS URL from the provider response — recon lead), Jev classifier (sanitized reply text only), Discord webhooks.

## Comparable baseline

No source-grounded comparable club SaaS. Stripe webhook verification mirrors Stripe's documented pattern; sessions use DB-backed hashed bearer tokens (stronger than stateless signed cookies); Web Push allowlist mirrors known push-service hosts. Calibrate severity against these, never to dismiss a demonstrated defect.

## Local execution limits (this run)

Source-only review plus **OS-sandboxed pure-module harnesses** (macOS `sandbox-exec`: no external network — loopback only; writes confined to the agent's scratch; `env -i` with explicit allowlist; CPU/fd/proc/file-size rlimits; wall-clock + RSS + scratch-disk watchdog). Harnesses load modules from the parent-verified `_build/dev` beams read-only (`elixir -pa …`), set needed `Application` env with `put_env`, and use dummy data only. **DB-dependent tests are excluded**: the test harness requires Docker/Testcontainers Postgres (a shared host service). Deployment facts (Stripe/Resend dashboard config, actual Fly secrets, proxy header behavior, VAPID keys set, cookie domain in production) are not source-established → `needs_validation` only.

## Prior coverage

None — no prior ledger or findings exist for this repo. Every unit is `new`-equivalent (`prior_status: "none"`).

## Companion selection summary

Selected where recon found the matching boundary: **WEB-PROTOCOL-AND-AUTH** (sessions/cookies, OAuth, CSRF, forwarded-header trust, webhook raw-body framing); **PROTOCOLS-RPC-AND-MESSAGING** (webhook event provenance, Oban replay/idempotency/fan-out, lease/fence progression); **RESOURCE-EXHAUSTION-AND-AVAILABILITY** (pre-auth work, rate-limit accounting on attacker-influenceable IP); **DATA-ISOLATION-AND-LIFECYCLE** (owner vs directory scope, member/operator read-model separation, retention/purge/anonymisation, import authority); **AI-AND-LLM** (Jev reply classifier deciding Reply Actions — untrusted content → privileged commands); **CLOUD-AND-DEPLOYMENT** (runtime config fail-open/closed, compile-gated harness, trusted-proxy `fly-client-ip`); **CLIENT-SIDE** (WebSocket origin/channel use). Excluded with reasons: **MEMORY-SAFETY-AND-BINARY** (no NIFs/FFI/native parsers; BEAM + Jason/Plug), **DESKTOP-MOBILE-AND-LOCAL-IPC** (no desktop/mobile/local-IPC surface), **SUPPLY-CHAIN-AND-RELEASE** (no runtime dependency resolution; repo-root CI out of scope; lockfile pins noted in the obvious sweep).

## Starting paths

`apps/phoenix/lib/dhc_web/router.ex`, `apps/phoenix/lib/dhc_web/endpoint.ex`, `apps/phoenix/lib/dhc_web/plugs/`, `apps/phoenix/lib/dhc_web/controllers/`, `apps/phoenix/lib/dhc_web/channels/`, `apps/phoenix/lib/dhc/{auth,onboarding,invitations,waitlist,members,membership,workshops,beginners_workshops,inventory,notifications,email,resend,stripe,stripe_sync,stripe_webhooks,member_announcements,training_announcements,workshop_announcements,discord}/`, `apps/phoenix/config/{config,runtime,dev,test}.exs`, `apps/phoenix/mix.exs`.
