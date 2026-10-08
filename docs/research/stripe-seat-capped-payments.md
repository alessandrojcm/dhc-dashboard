# Stripe seat-capped payments

**Research date:** 2026-10-08  
**Question:** How can a per-person €50 Beginners' Workshop payment flow retain the existing Payment Link's capacity behaviour, particularly when many non-Member invitees pay at once?

## Executive findings

- Stripe Payment Links have a built-in, **completed Checkout Session** limit.  It is not an inventory reservation: open/in-flight sessions do not count. Stripe documents that the link automatically deactivates once the limit is reached, but does **not** document a concurrency linearizability/overshoot guarantee or refund reopening semantics. Treat those two properties as undocumented rather than promising that a 17th concurrent payer cannot be charged.
- Stripe's limited-inventory guidance for ordinary Checkout Sessions explicitly makes inventory the application's responsibility: reserve it before creating the Session, set `expires_at` (30 minutes–24 hours), and put it back on `checkout.session.expired`. A Workshop-row lock plus a durable reservation is therefore the way to guarantee admission at session creation: only 16 reservations can exist, so the 17th request receives `full` before Stripe is called.
- PaymentIntents/Payment Element have no Session expiry or inventory primitive. The same application reservation is required, with an expiry/reaper and/or explicit PaymentIntent cancellation. Cancellation is only available for particular non-terminal statuses and is a race with a payer's confirmation; the authoritative re-read must decide whether to release the reservation or register/refund.
- The repository already has most of the durable-payment safety seam: `Dhc.Workshops.PaymentCommands` locks `Workshop → PaymentAttempt → Registration → Refund`, makes Stripe calls between locked transactions, and idempotently creates a PaymentIntent with `workshop-payment-attempt:<id>`. Its current capacity check happens while completing a **paid** attempt, so a concurrent over-cap payment is compensated with a refund. A strict pre-charge cap needs a durable reservation admitted under the Workshop lock, not only the existing post-payment registration gate.

## 1. Payment Links: `restrictions.completed_sessions`

### Documented contract

At Payment Link create/update, `restrictions[completed_sessions][limit]` is “the maximum number of checkout sessions that can be completed for the `completed_sessions` restriction to be met.” The Link object exposes the corresponding `count`: “the current number of checkout sessions that have been completed on the payment link which count towards” the restriction. [Payment Link create reference](https://docs.stripe.com/api/payment-link/create?query=restrictions.completed_sessions.limit) and [object reference](https://docs.stripe.com/api/payment-link/object?query=restrictions.completed_sessions).

Stripe's Payment Links guide makes the operational result clearer:

1. a link is “paid for” when a Checkout Session is complete (the guide also uses Stripe's `checkout.session.completed` webhook as the point); and
2. when the limit is reached, Stripe automatically deactivates the link; subsequent visitors cannot purchase and receive the inactive-link message. [Customize Payment Links: Limit the number of times a payment link can be paid](https://docs.stripe.com/payment-links/customize?dashboard-or-api=api#limit-the-number-of-times-a-payment-link-can-be-paid).

Thus it counts completed sessions, not payment attempts, page views, created Checkout Sessions, or open Checkout forms. In-flight forms are not holds; they are invisible to the documented `count` until completion. This avoids abandoned forms consuming capacity, but it also means a prospective 17th person can still open the Link while 16 other people are paying.

### Concurrent completion and refunds: what Stripe does *not* promise

The API and guide say *when* the Link deactivates, but neither specifies the atomic behavior when several already-open sessions complete simultaneously, whether an N+1 completion can occur, nor a maximum overshoot. The sources also say nothing about decrementing `completed_sessions.count`, reactivating a limit-deactivated Link, or freeing a completed-session allowance following a full or partial refund. A refund is a separate operation on a charge; it is not documented as undoing Checkout Session completion. [Refunds API overview](https://docs.stripe.com/api/refunds) and the Payment Link sources above.

Accordingly:

| Scenario | Supported statement |
| --- | --- |
| One payer after the completed-session limit has been reached | Stripe documents that the deactivated Link cannot be purchased from. |
| Several forms already open before the final completion | Open forms are not counted/held. Stripe publishes no contract that serializes their completions at the cap; do not claim “17th always sees full” without Stripe support confirmation or an account-specific test. |
| Refund after a completed session | Not documented to free capacity or reactivate the Link; plan on it **not** doing so unless Stripe confirms otherwise. |

### Per-person use and reconciliation

A Payment Link is a reusable public URL, not a per-recipient Checkout Session. It can prefill a recipient email with `prefilled_email`; the recipient may edit it. `locked_prefilled_email` is uneditable. The URL-parameter guide also supports a `client_reference_id` attached to the created Checkout Session and included in `checkout.session.completed`; it is limited to 200 alphanumeric/dash/underscore characters and Stripe warns not to put sensitive values in it. [Payment Link URL parameters](https://docs.stripe.com/payment-links/url-parameters). The Link's stored `metadata` is copied to **every** Checkout Session it creates, so it is Link-level rather than per-recipient. [Payment Link create reference: metadata](https://docs.stripe.com/api/payment-link/create?api-version=2026-04-22.dahlia).

Those facilities can reconcile a deliberately issued link URL with an application invitation, but they are not an authenticated entitlement: the URL/reference can be shared, `prefilled_email` can change, and a shared Link has one global `completed_sessions` counter. Payment Links therefore support a prefilled/locked email and non-secret correlation value, not a server-created per-person payment object with private mutable metadata.

## 2. Checkout Sessions with an application seat reservation

### Stripe facilities

`expires_at` is a Unix timestamp from **30 minutes to 24 hours** after Checkout Session creation; its default is 24 hours. An open Session can also be expired manually. After expiry customers cannot complete it and see the expired message. [Create Checkout Session: `expires_at`](https://docs.stripe.com/api/checkout/sessions/create#create_checkout_session-expires_at) and [Expire a Checkout Session](https://docs.stripe.com/api/checkout/sessions/expire).

Stripe's own limited-inventory guidance says to reserve the item in the application, set/perform Session expiry, and listen for `checkout.session.expired` to “return to inventory any items reserved in the expired session.” [Manage limited inventory](https://docs.stripe.com/payments/checkout/managing-limited-inventory?payment-ui=stripe-hosted). That is affirmative evidence that Checkout does not provide a general inventory or seat-hold counter.

For an invitee, the server can create a one-off `mode=payment`, quantity-one Session after it has admitted a reservation; it may use `customer` for an existing Stripe Customer or `customer_email` to prefill a new customer's email, plus Session `metadata`/`client_reference_id` for non-secret reconciliation. Supplying `customer` with a valid email pre-fills and locks that email; `customer_email` is only a prefill for a Customer created during the flow. [Create Checkout Session: `customer` and `customer_email`](https://docs.stripe.com/api/checkout/sessions/create#create_checkout_session-customer).

### Reservation protocol and races

1. In a database transaction, lock the Workshop, verify it is public/open, that this invitee has no active registration/reservation, and that `active registrations + unexpired held reservations < max_capacity`; insert a durable reservation/attempt with a deadline.
2. After committing, create/reuse that invitee's Checkout Session with a stable idempotency key and its deadline as `expires_at`; then save the Session ID under the relevant row lock. If creation definitively fails, release the reservation in a separate locked transaction.
3. On `checkout.session.completed` (and, where applicable, `checkout.session.async_payment_succeeded`), retrieve/validate the Session and, under the Workshop lock, convert its own reservation to the Registration. Do not make fulfilment depend only on the success redirect: Stripe directs integrations to webhooks for reliable fulfilment. [Checkout fulfilment](https://docs.stripe.com/checkout/fulfillment) and [Checkout events](https://docs.stripe.com/api/events/types#event_types-checkout.session.completed).
4. On `checkout.session.expired`, idempotently release **that** still-held reservation. Also run a deadline reaper: webhooks can be delayed/retried/missed and the app should not indefinitely hold a seat. If a Session is manually expired, process the same transition.
5. A completion that races expiry/release must re-read the reservation and provider object under the Workshop lock. If Stripe accepted payment after the app no longer has a valid reservation, it cannot create a 17th Registration; record the paid attempt and enter the existing compensating-refund path.

This does guarantee “the 17th *reservation request* sees full” if the count and reservation insertion are protected by the existing Workshop lock (or an equivalent serializable/constraint-backed allocation). It cannot guarantee Stripe will never collect an edge-racing payment after the business deadline without a compensation route, so that rare outcome is “do not admit/auto-refund,” not an extra seat.

| Aspect | Checkout Session + durable reservation |
| --- | --- |
| Concurrent payers | Strict admission limit at reservation creation; open Sessions consume a temporary seat. |
| Abandonment | Seat remains unavailable until manual/timed Session expiry plus webhook/reaper release; Stripe minimum expiry is 30 minutes. |
| Refund | A refund should follow the Workshop refund policy. Whether it reopens capacity is an application policy: release/replace the Registration under the Workshop lock; Stripe has no inventory counter to adjust. |
| “17th sees full” | Yes, at the app's admission endpoint, provided all entry paths take the same lock/reservation allocation. Do not instead create Sessions first and count later. |

## 3. PaymentIntent + Payment Element with application reservation

PaymentIntents track payment state but have no `expires_at` parameter and no inventory reservation feature. Stripe recommends creating one when the amount is known, reusing it for an interrupted checkout, and using an application idempotency key tied to the cart/customer session. [Payment Intents API](https://docs.stripe.com/payments/payment-intents#best-practices).

The same pre-intent reservation transaction is needed: admit the invitee's one seat under the Workshop lock, create/reuse one €50 PaymentIntent outside the transaction using `workshop-payment-attempt:<attempt-id>`, store its ID, and give only its client secret to the intended browser. Associate the opaque invitation/reservation ID in non-sensitive metadata; Stripe says metadata must not contain sensitive/PII data. [PaymentIntent metadata](https://docs.stripe.com/api/payment_intents/create?query=metadata).

### Abandonment, cancellation, and completion race

- A new Intent starts as `requires_payment_method`; a failed payment attempt returns to that state, while an abandoned authentication can be `requires_action`. [PaymentIntent lifecycle](https://docs.stripe.com/payments/paymentintents/lifecycle).
- The cancellation endpoint accepts only `requires_payment_method`, `requires_capture`, `requires_confirmation`, `requires_action`, and rarely `processing`. Successful cancellation prevents further charges; for `requires_capture` it automatically refunds remaining capturable funds. The documented cancellation reason includes `abandoned`. [Cancel a PaymentIntent](https://docs.stripe.com/api/payment_intents/cancel).
- The lifecycle documentation says cancellation is possible before `processing` or `succeeded` and releases held funds, but cancellation of asynchronous-method `processing` states has narrow, varying windows and can fail. A PaymentIntent can also transition to `canceled` after too many confirmations. [PaymentIntent lifecycle: Canceled](https://docs.stripe.com/payments/paymentintents/lifecycle).
- Therefore a reservation reaper may first retrieve the Intent and cancel only a cancelable intent, then release its seat under the Workshop lock. It must handle the race where customer confirmation wins: authoritative provider retrieval plus locked application state chooses registration for `succeeded` (or a compensating refund if the reservation is no longer admissible), not a blind release.
- Stripe says to fulfil from `payment_intent.succeeded` webhooks, rather than a browser response, because the payer can leave the page after payment. [Verify PaymentIntent status](https://docs.stripe.com/payments/payment-intents/verifying-status#monitor-a-paymentintent-with-webhooks).

| Aspect | PaymentIntent + durable reservation |
| --- | --- |
| Concurrent payers | Strict admission limit is entirely app-side; only a locked reservation allocator makes the 17th request full. |
| Abandonment | No Stripe expiry. App reaper/deadline and cancel API are required; cancellation is status-dependent and races confirmation. |
| Refund | Once `succeeded`, freeing/replacing capacity follows the app's Registration/refund policy; a Stripe refund does not itself manage a seat. |
| “17th sees full” | Yes at intent/reservation creation with the same lock and one-seat invariant. A payment that wins a reaper race must be compensated, never registered as seat 17. |

## 4. Fit with the existing Workshop payment model

The current external flow already creates a durable external `PaymentAttempt` under the Workshop lock, creates a Checkout Session after the transaction, records its ID, validates the returned Session, and on completion creates a Registration under the same lock. `capacity_available/1` counts active Registrations, not open external attempts. Therefore 17 simultaneous people can each obtain an external Checkout Session while capacity is 16; on the 17th paid completion, `register_external/4` reaches `:full` and writes a compensating Refund instead of a Registration. `apps/phoenix/lib/dhc/workshops/payment_commands.ex` lines 283–308, 673–690, and 1283–1292.

For member Payment Element flow, the same structure creates/reuses a PaymentIntent with idempotency key `workshop-payment-attempt:<id>` outside the transaction and compensates a paid attempt that finds capacity full. Lines 260–280, 593–617; ADR 0012 and ADR 0027 specify that every valid paid attempt concludes exactly once with a Registration or compensating Refund and that Stripe calls occur between locked reads. [ADR 0012](../adr/0012-durable-workshop-payment-and-refund-workflows.md) and [ADR 0027](../adr/0027-workshop-payment-commands-share-one-lock-order.md).

The three alternatives sit beside that seam as follows:

| Option | New/adapted provider path | Needed domain addition | Strict-cap result |
| --- | --- | --- | --- |
| Payment Link limit | A single reusable Stripe Link; completion reconciled by URL `client_reference_id`/webhook. | Invitee entitlement/reconciliation still needed; Link count is external. | Stripe documents deactivation after completed-session limit, but documentation does not establish an in-flight concurrency or refund-capacity contract. Not a defensible app-level strict guarantee. |
| Per-invitee Checkout Session | Retain/adapt existing external `start_external_payment` and its Session adapter. | One durable held-seat status/deadline coupled to the attempt; expire webhook + reaper. | Strict pre-charge admission in app; edge race is compensated, not oversold. |
| PaymentIntent + Payment Element | Retain/adapt the existing member Intent code and idempotency key for an external invitee. | Same reservation, app deadline/reaper and Intent cancellation/retrieval logic. | Strict pre-charge admission in app; edge race is compensated, not oversold. |

This is a fact/trade-off report, not a selection. The key distinction is between (a) a Stripe limit that is defined in terms of completed Sessions and (b) an application-owned allocation that counts registrations **and holds** atomically. Either custom flow must preserve the ADR 0027 boundary: no Stripe request inside the lock transaction, re-read authoritatively after it, keep the existing idempotency key per Payment Attempt, and use the current compensating Refund path as the backstop for provider/application races.

## Primary sources

All external sources below are Stripe documentation/API references, retrieved 2026-10-08.

1. [Payment Link create API: `restrictions.completed_sessions.limit`](https://docs.stripe.com/api/payment-link/create?query=restrictions.completed_sessions.limit)
2. [Payment Link object API: `completed_sessions.count` and `limit`](https://docs.stripe.com/api/payment-link/object?query=restrictions.completed_sessions)
3. [Customize Payment Links: completed-payment limit](https://docs.stripe.com/payment-links/customize?dashboard-or-api=api#limit-the-number-of-times-a-payment-link-can-be-paid)
4. [Payment Link URL parameters](https://docs.stripe.com/payment-links/url-parameters)
5. [Create Checkout Session API](https://docs.stripe.com/api/checkout/sessions/create), especially `expires_at`, `customer`, and `customer_email`
6. [Manage limited inventory with Checkout](https://docs.stripe.com/payments/checkout/managing-limited-inventory?payment-ui=stripe-hosted)
7. [Expire a Checkout Session API](https://docs.stripe.com/api/checkout/sessions/expire)
8. [Checkout fulfilment](https://docs.stripe.com/checkout/fulfillment) and [event types](https://docs.stripe.com/api/events/types)
9. [Payment Intents overview/lifecycle](https://docs.stripe.com/payments/payment-intents) and [lifecycle states](https://docs.stripe.com/payments/paymentintents/lifecycle)
10. [Cancel a PaymentIntent API](https://docs.stripe.com/api/payment_intents/cancel)
11. [PaymentIntent status verification/webhooks](https://docs.stripe.com/payments/payment-intents/verifying-status)
12. [Refunds API](https://docs.stripe.com/api/refunds)
