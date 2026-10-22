# FINDINGS DETAIL — dhc-dashboard `apps/phoenix` run-1

This run produced **no confirmed medium, high, or critical findings**, so this
file contains no confirmed-finding reproductions. Per the skill's reporting
contract, the run does not invent findings to fill the file: the confirmed set
is empty because the single proposed-confirmed candidate
(`dhc.auth.logout.does-not-revoke-socket-tokens`) was demoted to
`needs_validation` by its independent Phase-3 verifier — the decisive boundary
observation (post-logout socket-token acceptance and event delivery) requires a
DB + PubSub fixture that the run's sandboxed-source-and-local-only policy
excluded (the test harness needs Docker/Testcontainers Postgres, a shared host
service).

The nine retained leads — each with a complete source trace, exact blockers,
and a safe owner-observed or bounded local validation plan — are documented in
full in:

- [`NEEDS-VALIDATION.md`](NEEDS-VALIDATION.md) — the nine needs-validation leads.
- [`findings.json`](findings.json) — the structured records (9 `needs_validation`,
  1 `rejected`), the single source of truth for traces, evidence, and plans.
- [`coverage-ledger.json`](coverage-ledger.json) — all 57 coverage units with
  per-check evidence, including the four sandboxed pure-module local checks
  whose outputs were promoted to `agents/<id>/artifacts/`.

For the closest thing to a confirmed reproduction available under this run's
boundary, see the logout/socket lead (item 4 in NEEDS-VALIDATION.md): the
sandboxed pure-module harness
(`agents/w3-relogin/artifacts/check-01.txt`) generated and compared the session
vs socket verification query shapes from the dev beams, confirming the two
credential contexts are independent — the source-level precondition of the
claimed boundary result. Completing the observation (issuance → logout →
residual acceptance → open-socket event delivery) is exactly the bounded local
step named in that lead's validation plan.
