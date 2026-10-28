# Offer-round email delivery (ALE-428)

## Persistence and scope

Only automatic `send_due_batch` Contact emails opt into planning. The shared
`contact/4` still calls `IntakeEmails.deliver/5`, which selects the recipient and
pay/confirmation variant, renders the template, creates the optional Reply-To
binding and writes the occasion. Its opaque plan is collected in proposal order
inside the existing Commands transaction, then `enqueue_offer_round/2` writes
chunks of at most 100. A rollback discards all of that work. The transient plan
list is not a background buffer: no work survives except committed Oban jobs.

Each `Dhc.Email.OfferRoundWorker` job contains a round UUID, zero-based chunk
index, count, and a purpose-bound encrypted payload. The payload freezes ordered
Swoosh envelopes, including sender, recipient, Reply-To, subject, template alias,
variables and Intake URL, plus its deadline and provider idempotency key
`beginners-offer-round:<round UUID>:<chunk index>`. Decryption happens only for
delivery. Existing individual jobs and all other email paths are unchanged.

There is **no new migration**. Oban already provides durable storage, retry and
completion state. The prerequisite `resend_request_gate` migration must remain;
it is additive and runs through the normal Fly release command. HTTP and pacing
run after the command transaction, through Swoosh and the shared request gate.

## Validation and retry policy

Provider references checked on 28 October 2026:

- [Batch API](https://resend.com/docs/api-reference/emails/send-batch-emails):
  100 personalized messages, templates supported, ordered success receipts,
  request-level idempotency retained for 24 hours.
- [Official CLI](https://resend.com/docs/cli): strict validation is the default;
  the entire request fails on any validation error. Permissive is opt-in.
- [Errors](https://resend.com/docs/api-reference/errors): rate limiting and
  concurrent idempotent requests are retryable; invalid idempotent payloads
  require intervention.
- Installed Swoosh 1.27.1 supports batch templates and the first envelope's
  idempotency header, but exposes neither a permissive-mode option nor per-item
  errors. This implementation keeps strict mode.

Invalid local addresses/subjects refuse the command before anything commits.
Provider 4xx rejections other than rate limits and concurrent idempotent requests
cancel the **whole chunk**, with an explicit Sentry/log signal identifying its
round, chunk, affected count and status. Valid recipients in that rejected chunk
also need operator follow-up; the system does not silently mark them delivered.
It does not automatically split even a definite rejection.

Timeouts, network failures, 429 and 5xx retry unchanged envelopes and the same
key. Other chunks have independent jobs, so a completed chunk is not resent when
another retries. Exhaustion cancels with an explicit reconciliation signal.

The seal lasts 24 hours. A conservative delivery deadline starts at enqueue,
one minute short of 24 hours (earlier than the provider's retention window).
The HTTP wrapper checks the deadline again **after** waiting for admission.
Expired/tampered credentials never produce another send or a fresh key. Keep
the endpoint secret stable while queued jobs are live.

## Operations

Sentry's final hook recognizes the new worker and removes nested envelopes,
ciphertext, provider bodies and exception/message payloads. Ordinary retry
reports are suppressed; unexpected exceptions and terminal failures remain
visible. Terminal metadata includes only safe job identifiers, counts and status.
The Intake Email ledger still means **queued**, not provider-confirmed delivery.

For a terminal signal, inspect the round/chunk's Oban state and reconcile with
Resend's request log by its stable key before taking any action. Do not edit
sealed envelopes, change membership under a used key, blindly retry expired
jobs, or create a new key to bypass an ambiguous outcome. After reconciliation,
staff can use the existing individual link-resend command for people proven
not to have received their email. Do not put decrypted envelopes into logs or
tickets.

Deploy the code normally; no UI, OpenAPI or provider-template changes are needed.
Do not regroup already queued individual jobs. Local verification uses stubs
only; it must never send real club emails.

## Verification (28 October 2026)

Full Phoenix suite: **2,904 passed, 4 excluded**. Credo (`--all`), architecture,
compilation and formatting pass. `mix precommit` still exits 1 for the existing
Bandit/JOSE audit advisories, not for test failures. Request tests use local
Resend stubs, including real Swoosh HTTP and Oban retry/reporting integration.
The local standards/spec review found no remaining issues; the independent
review subagent was unavailable because its invocation was permission-blocked.
