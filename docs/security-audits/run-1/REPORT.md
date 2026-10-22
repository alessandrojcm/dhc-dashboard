# Security Audit Report — dhc-dashboard `apps/phoenix`

## 1. Run profile and scope

| | |
|---|---|
| Run | `dhc-dashboard-phoenix-run-1` |
| Profile | `standard`, **scoped** to `apps/phoenix` only |
| Source ref | `4de8bf54833a5cf38d7f6eda06bf93525278a628` (GitButler workspace commit); the 3 dirty repo paths are outside `apps/phoenix` — the Phoenix subtree is clean at this ref |
| Budget | none set (`budget: null`) |
| Execution policy | **sandboxed-source-and-local-only**. Target-controlled execution ran only inside an OS-enforced `sandbox-exec` sandbox: no external network, empty allowlisted environment, read-only target, scratch-only writes, wall-clock/RSS/disk watchdogs, CPU/NOFILE/FSIZE rlimits. Pure-module harnesses loaded the pre-built `_build/dev` beams. No DB-backed tests ran (the test harness requires Docker/Testcontainers Postgres — a shared host service, prohibited); the suite was never started, and no deployed endpoint, provider API, or shared service was contacted. |
| Prior runs | None existed (no prior ledger or findings for this repo); nothing was carried. Every unit was seeded fresh (`prior_status: none`). |
| Companion selection | WEB-PROTOCOL-AND-AUTH, PROTOCOLS-RPC-AND-MESSAGING, RESOURCE-EXHAUSTION-AND-AVAILABILITY, DATA-ISOLATION-AND-LIFECYCLE, AI-AND-LLM, CLOUD-AND-DEPLOYMENT, CLIENT-SIDE (WebSocket unit). Excluded repo-wide with reasons: MEMORY-SAFETY-AND-BINARY (no NIF/FFI/native parsers — recon-verified), DESKTOP-MOBILE-AND-LOCAL-IPC (no such surface), SUPPLY-CHAIN-AND-RELEASE (no runtime dependency resolution; root CI/release pipeline out of scope). |

**Agents spent vs planned**: 4 recon + 21 hunters (9 + 11 + 1 Dockerfile unit) + 2 post-wave critics + 2 final-clean critics + 9 Phase-3 verifiers + 11 Phase-5 verifiers (10 records + 1 fresh re-verification of a material replacement) = **49 agent invocations**. The run stayed within the standard profile's structure (recon → waves 1–3 with per-wave critics → distinct final-clean critics → candidate validation → record verification).

**This is a partial-coverage statement by construction**: a scoped run of one monorepo slice. `apps/web` (SvelteKit frontend), `packages/api-client`, and the repo-root CI/deploy configuration are **out of scope**; where a finding's decisive fact lives in those areas or in a deployed provider, it is recorded as `needs_validation` with an owner-observed plan. The two SvelteKit-facing facts that did enter evidence (forwarding-secret behavior, `customerId` client flow) are cited as out-of-scope context only.

**Deferred/blocked coverage**: none — 57/57 units reached a terminal state (47 covered, 10 candidate), 0 planned, 0 blocked, 0 deferred, 0 out-of-scope. The final coverage-critic passes returned `stop: true` with no accepted work. No carried same-source confirmations or changed-source revalidations exist (no prior runs).

## 2. Security posture summary

The Phoenix backend shows a **mature, deliberately-engineered security posture**: a single capability registry (`Dhc.Auth.Capabilities`) with capability-named router pipelines and owner/assignment-scope refusal at the plug level; hashed DB-backed session and magic-link tokens with non-enumerating responses; HMAC-verified provider webhooks over exact raw bodies with constant-time compares and fail-closed secret handling; opaque signed acceptance handles with an advisory→row lock graph and fenced Stripe progression; single command boundaries for all money and availability transitions with declared lock orders, Stripe called only between transactions, and idempotency keys; a push-service host allowlist re-checked at send with redirects disabled; sealed email credentials; intake-token redaction from logs and Sentry; and a compile-gated, loopback-bound E2E harness.

No **confirmed** vulnerability survived the candidate gate: the one proposed-confirmed candidate (logout not revoking socket credentials) was correctly demoted to `needs_validation` by its independent verifier, because the decisive observation (post-logout socket-token acceptance and event delivery) requires a DB-backed fixture that the run's execution boundary excludes. **Nine `needs_validation` leads** remain, each with a complete source trace, a decisive missing fact, and a safe owner-observed or local validation plan. They cluster into three themes: (1) trust in the deployed network edge (Fly header overwrite, forwarding-secret equality), (2) missing route-level throttles on two public enumeration/timing oracles, and (3) unvalidated caller-controlled values that reach Stripe (returnUrl, customerId) and a provider-supplied URL fetcher.

## 3. Confirmed findings

**None.** No candidate met the confirmed bar under this run's sandboxed-source-and-local-only policy. The clean result is stated without inventing lower-severity findings; see the needs-validation table for the remaining leads.

## 4. NEEDS VALIDATION (prioritized leads — no severity, not confirmed vulnerabilities)

| # | Title | Repository trace (start → sink) | Exact blocker | Next step |
|---|---|---|---|---|
| 1 | Public external checkout forwards a caller-selected return destination | `router.ex:364` → `workshops_controller.ex:221` → `payment_commands.ex:287,1470` → `stripe_adapter/live.ex:35` | Stripe's handling of an unrelated embedded-Checkout `return_url` host is provider behavior not established by source or the fake-boundary test | Owner inspects effective Stripe embedded-Checkout policy/config (no session creation, no API calls) |
| 2 | Member workshop payment accepts an unbound Stripe Customer | `router.ex:507` → `workshops_controller.ex:165` → `workshops.ex:352` → `payment_commands.ex:260,1445` → `stripe_adapter/live.ex:25` | Whether a PaymentIntent for another Customer exposes/permits that Customer's saved methods via this client-secret flow, and whether a member can obtain another's Customer ID | Owner reviews existing authorized test-mode observations (synthetic Customers only; no new audit traffic) + identity/API review for Customer-ID exposure paths |
| 3 | Concurrent membership deactivation may defeat last-editor preservation | `member_roles_controller.ex:14` → `roles.ex:41,79,83` vs `auth.ex:624` (no shared lock; `capabilities.ex:239` count without profile locks) | The concurrent-commit interleaving has not been observed against PostgreSQL | Barrier-controlled two-transaction regression test in an isolated PostgreSQL env; assert the active-editor set can never become empty |
| 4 | Current-device logout may leave its socket credential and established socket active | `auth_session_controller.ex:345,364` → `auth.ex:581` → `principal_token.ex:187` → `user_socket.ex:78` → `notification_channel.ex:79` | Post-logout socket-token acceptance and event delivery need a DB+PubSub fixture (sandbox excluded DB) | Isolated Phoenix test fixture: session → socket token → socket join → logout → assert rejection vs residual 60 s credential/open-socket events (empty payloads only) |
| 5 | Public invitation verification exposes a DOB oracle without application throttling | `router.ex:354` → `invitations_controller.ex:40` → `invitations.ex:96,546` → `invitations_http.ex:18` (200 vs 422) | Whether the deployed ingress applies an effective rate limit to this route | Owner inspects effective ingress/proxy policy; optional staged seeded-dummy DOB sequence (non-production only) |
| 6 | The magic-link IP limiter relies on Fly to protect its client-IP fallback | `router.ex:668` → `client_ip.ex:35` → `magic_link_rate_limit.ex:96,127` | Whether every route to Phoenix terminates at Fly's edge and Fly overwrites caller-supplied `fly-client-ip` | Owner inspects effective Fly service/listener/network attachments and edge header behavior (no live probing) |
| 7 | Optional forwarding secret can collapse the magic-link IP quota onto shared egress | `router.ex:668` → `magic_link_rate_limit.ex:54,77` ← `client_ip.ex:35` ← `runtime.exs:111` (optional secret) | Deployed Worker/Phoenix `TRUSTED_FORWARDING_SECRET` presence+equality, and the fallback IP attribution of server-side requests | Owner verifies secret equality without disclosure; establish Worker-request IP attribution from existing telemetry/config only |
| 8 | Receiving downloads accept unrestricted HTTPS destinations | `resend_webhooks_controller.ex:32` → `intake_replies.ex:155,177` → `reply_worker.ex:21` (no enabled? re-check) → `intake_replies.ex:339` → `receiving.ex:62` | Resend's download-URL provenance guarantee; deployed egress policy for private/loopback/link-local; effective deployed feature state + queued-job reachability | Owner inspects effective `IntakeReplies.enabled?` + ReplyWorker job state; if any job can execute, review Resend URL provenance and egress policy (no test traffic) |
| 9 | Public Waitlist registration may reveal email presence through response timing | `router.ex:356` → `waitlist_controller.ex:67,70` → `waitlist.ex:708,714,720` → `email_refusals.ex:35` (state-dependent work; identical bodies) | Whether the latency distributions are remotely distinguishable (needs a running Phoenix/Postgres fixture) and ingress limits | Isolated disposable env: seeded synthetic records, 44-request bounded measurement; owner inspects ingress limits separately |

Full records with complete traces, evidence, blockers, and validation plans: `findings.json`; per-lead detail in `NEEDS-VALIDATION.md`.

## 5. Hardening notes and positive source patterns

**Positive patterns observed** (for future runs and reviewers): capability-named pipelines with owner/assignment-scope refusal at plug init; hashed single-use 15-minute magic links with outstanding-token invalidation and a non-enumerating, short-circuiting rate limiter; Svix/Stripe webhook verification over exact cached raw bodies with fail-closed secrets and parameter-log disabling on credential-bearing routes; advisory→row lock graphs with probe-only reads and fenced/leased Stripe progression; per-refund `follows_refund_id` chains and one `insert_refund/4`; intake-token HMAC with generation-bumped rotation and log/Sentry redaction verified by controller contract tests; Web Push endpoint allowlist with label-boundary suffix matching, re-checked at send, redirects disabled (sandbox-fuzzed in this run: lookalike hosts, userinfo, encoded hosts all rejected); E2E harness compile-gated and loopback-bound with a header-key check; sealed email variables/Reply-To with kind-specific age limits and fail-closed decryption; keyed-notification uniqueness `(principal_id, notification_key)` with ON CONFLICT DO NOTHING and signal-only-new rows.

**Hardening notes** (26 collected; highlights):
- Stripe webhook tolerance has **no upper timestamp bound** — not exploitable without the signing secret (the HMAC binds timestamp+body), but add a skew ceiling as defense in depth.
- `OnboardingController` accepts caller-supplied `mandateContext.ipAddress/userAgent` for Stripe mandate data — consider deriving server-side.
- Intake-email subject `firstName` substitution does not reject internal CR/LF (own-address delivery only; no cross-principal impact shown).
- The transactional email worker logs recipient addresses (PII in logs; no unauthorized reader established).
- `DhcWeb.Router` runs `:api` before `:intake_link`, so an early `:api` halt can bypass the intake plug's `Referrer-Policy`/`Cache-Control` headers — apply those static headers earlier if the guarantee must cover parser rejections.
- The push-endpoint validator permits non-default ports on allowlisted hosts (no unintended-host impact shown).
- `DoorView.load/2` hydrates roster PII before the assignment check; the denial path renders nothing, but a minimal-resource check first would avoid loading PII pre-authorization.
- Waitlist import and the Jev eval CLI read whole caller-chosen files with no size/row caps (operator-run only).
- E2E harness key has a predictable test-only default — keep `E2E_SERVER` out of deployed builds.
- `EmailRefusals` does lock-free cross-table reads: concurrent public registration + staff invitation issue for the same email can both pass refusal checks (staff authority still required; no unauthorized principal shown).
- Discord Doctor's guild-member cache retains roster data up to 60 s (explicit window; eligibility re-evaluated per request).
- Keep the Discord-assignments Mix task host-restricted: its principal-ID args are actor selectors, not OS-caller authentication.
- In-flight Web Push/Reply sends may complete concurrently with retention/deletion (recipients remain the original subscriber/inbox; serialize if the lifecycle contract requires canceling in-flight sends).
- Dockerfile.dev has no `USER` directive and exposes 4000 (dev-only; Compose-mounted source; no host-boundary crossing shown).
- Promotion-code secrecy: the pricing preview distinguishes valid from invalid codes by design — do not rely on code secrecy operationally.

## 6. Coverage summary

- **Ledger**: 57 units — 47 `covered`, 10 `candidate`, 0 planned/blocked/deferred/out-of-scope. Final ledger validation: **PASS** (skill validator).
- **Candidates**: 10 unique fingerprints from 3 waves (12 raw, deduplicated: one root cause found independently by two hunters; one claim disproved by fresh re-hunt after critic reassignment).
- **Validation**: all 9 live candidates verified by fresh Phase-3 verifiers (1 proposed-confirmed demoted to needs_validation; 8 tightened). All 10 final records passed Phase-5 fresh verification (6 verified; 4 replacements applied — 3 non-material directly, 1 material replacement re-verified by a fresh agent and applied). `findings.json` validation: **PASS** (9 needs_validation, 1 rejected).
- **Critic loop**: post-wave-1 critic accepted 5 units (Discord Doctor/join-grants/assignments CLI/eval CLI/webhook framing); post-wave-2 critic accepted 5 read-model/keyed-worker units + 3 source-answerable reassignments (fresh owners re-hunted all three: 1 tightened, 1 disproved→rejected, 1 promoted then demoted by its verifier); final-clean critic found the Dockerfile container unit (covered); confirmation critic returned `stop: true` with no work remaining.
- **Local checks**: 4 sandboxed pure-module harnesses ran (parent smoke; Web Push endpoint allowlist fuzz; assignment-scope authorization check; session/socket query-shape check), all inside the OS sandbox with watchdogs; their outputs were promoted via the race-safe procedure and are cited in ledger evidence.
- **Exclusions**: memory-safety (no NIF/FFI — recon-verified), desktop/mobile/IPC (no surface), supply-chain/release (no runtime dependency resolution; root CI out of scope). Scoped-out: `apps/web`, `packages/api-client`, root CI/deploy config — surfaced only as needs_validation blockers where decisive.

## 7. Rejected records

One record was rejected during validation and is retained in `findings.json` so future runs do not repeat it without changed evidence: `inventory.container-detail-item-location-disclosure` — the wave-2 claim was disproved by the fresh wave-3 re-hunt: container detail (with contained item IDs and category summaries) is the explicitly documented ALE-106 member-readable API contract (router scope, controller moduledoc, member-role controller test, OpenAPI), so no authorization control is missing; the catalog's location-withholding and the container-detail contract deliberately coexist.

## 8. Artifacts

- `run-metadata.json`, `architecture.md`, `coverage-ledger.json` (57 units, PASS)
- `findings.json` (10 records, PASS) — 9 `needs_validation` + 1 `rejected`
- `NEEDS-VALIDATION.md`, `FINDINGS-DETAIL.md` (this run has no confirmed medium+ records, so the detail file records that fact and points to the needs-validation leads)
- Per-agent evidence: `agents/<id>/artifacts/*` (4 promoted local-check artifacts)
- Hunter/verifier inputs and outputs: `results/`, `verify-inputs/`, `verify-outputs/`, `p5-inputs/`, `p5-outputs/`
- Parent tooling: `tools/` (sandbox runner, watchdog, race-safe promotion, ledger/brief/findings builders)
