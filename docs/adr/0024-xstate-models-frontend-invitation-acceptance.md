# XState Models Frontend Invitation Acceptance Orchestration

**Status:** Accepted  
**Date:** 2026-09-16  
**Tags:** frontend, sveltekit, onboarding, invitation-acceptance, xstate

## Context

Invitation Acceptance is one workflow, but the SvelteKit frontend implemented it across the initial page load, the resume page, four remote commands, and two cookie helpers, each interpreting Phoenix's safe-view `state` on its own. The interpretations had already drifted: Phoenix answers `restartVerification` on a 200 and `restart_verification` on a 409/422, and the frontend matched only the latter, so a 200 restart left the acceptance-proof cookie in place. Payment, verification, restart, resume, and completion UI states were implicit in component control flow (`stripe`, `paymentElementReady`, `processPayment.pending`, `paymentError`), and the tests covered cookie helpers rather than workflow transitions (GH-509).

Phoenix (`Dhc.Onboarding.Acceptance`, GH-507 / ADR 0013 / ADR 0014) is and remains the only durable authority for invitation, Discord verification, and payment state. What the frontend lacked was an explicit model of *its own* orchestration and presentation.

## Decision

Introduce XState v5 and `@xstate/svelte`, and model the frontend's half of Invitation Acceptance as two machines that share a typed vocabulary but never a running actor.

**Shared vocabulary** — `apps/web/src/lib/invitation-acceptance/vocabulary.ts` names Phoenix's safe-view statuses once (`awaitingDiscord`, `discordVerified`, `discordCollision`, `discordUnavailable`, `paymentReady`, `paymentPending`, `paymentNeedsAction`, `paymentTerminal`, `accepted`, `restartVerification`) and parses both Phoenix spellings onto it with a valibot schema. An unknown status is rejected, not rendered as step 1. `presentation.ts` is an exhaustive `Record` from status to step/title/description.

**Server decision machine** — `apps/web/src/lib/server/invitation-acceptance/decision.ts` is a pure XState machine run only through `initialTransition`/`transition`. Input is request-local evidence (does this browser hold acceptance proof?) plus one typed Phoenix result; output is a route outcome (`SHOW`, `REDIRECT_TO_SUCCESS`, `RESTART_VERIFICATION`, `UNAVAILABLE`, `REJECTED`) and the cookie effects it requires (`clearAcceptanceProof`, `storeProof`, `establishSignInHandoff`), returned as data. No actor is created, so nothing can leak across SvelteKit requests. `workflow.ts` converges every path — initial page, resume (with its retry-once rule), continue, payment, verification, Discord restart — on that one decision; `apply.ts` performs the effects and turns the outcome into render data or a thrown redirect/error.

**Ports and adapters** — the workflow speaks only `InvitationAcceptanceApi` (workflow operations returning typed `AcceptanceApiResult`s) and `AcceptanceCookieStore` (`readProof`, `storeProof`, `clearProof`, `storeSignInPrefill`). Production adapters wrap the generated `@dhc/api-client` operations and SvelteKit `cookies`; `testing.ts` holds in-memory adapters that script Phoenix answers and record effects. Routes and remote functions are thin: build deps, run one workflow operation, apply the outcome.

**Browser UI machine** — `apps/web/src/lib/invitation-acceptance/payment-machine.ts` models the payment step's asynchronous work as explicit states: `deciding → initializing → ready → preparing → submitting`, with `failed` (recoverable), `expired` (proof gone; only re-verifying continues), and `unavailable` (Stripe failed to load). Stripe browser objects stay in the host component as provided actors (`loadPaymentElement`, `preparePayment`) and the remote form submission as a provided action (`submitPayment`). The machine has no `accepted` state: success leaves the page by redirect after Phoenix reconciles. It is instantiated per component with `useMachine` and stopped with it; `paymentSubmitPresentation` is an exhaustive `Record` from machine state to submit-control UI.

## Consequences

- A new Phoenix status is handled in one place: the vocabulary schema, the presentation record, and (if it changes routing) one guard in the decision machine. The initial page, resume page, and every command cannot disagree because they do not each interpret it.
- Cookie effects are requested by the decision and performed by `applyRouteEffects`; a route cannot clear or set the proof on its own initiative.
- Transport failures are explicit: a timeout or 5xx keeps the proof and is `UNAVAILABLE`; a 409 without a body is a restart; a 402 with a state body is a recoverable payment failure.
- The old acceptance-proof and sign-in-handoff helper tests are replaced by boundary tests (`decision.test.ts`, `workflow.test.ts`, `apply.test.ts`), actor tests (`payment-machine.test.ts`), and a browser test that renders every machine state (`payment-submit.browser.test.ts`). The generic trusted-cookie parsing tests remain.
- The ast-grep rule `no-xstate-actor-in-server-code` (`mise run ast-lint`) rejects `createActor`/`useMachine`/`useActor` under `src/lib/server/**`, `*.server.ts`, `*.remote.ts`, and `+server.ts`. Never create or start an invitation actor at module scope, and never hydrate a snapshot that contains an active invocation: restored invocations restart, and payment and acceptance commands rely on Phoenix idempotency and reconciliation instead.
- The confirm-credentials and Discord steps stay server-data-driven; they are plain forms and redirects. Extend the UI machine only when a step gains asynchronous browser work of its own.

## Considered options

- **Keep the imperative helpers and add tests.** Rejected: the tests would still restate cookie operations, and a fourth path interpreting `state` would have nothing to stop it drifting.
- **One universal actor shared between server and browser, hydrated from a snapshot.** Rejected: SvelteKit server modules are shared across requests, hydration restarts invocations, and it would make an XState snapshot a competing source of truth to Phoenix.
- **A hand-written reducer instead of XState.** Viable, but XState's pure `transition` gives the decision machine its effect list for free, and the same vocabulary drives a browser actor with invoked promise actors, which a reducer would have to grow into.
