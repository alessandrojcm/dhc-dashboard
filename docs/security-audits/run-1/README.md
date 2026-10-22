# Security audit run-1 — dhc-dashboard `apps/phoenix`

**Date:** 2026-10-22 · **Profile:** standard, scoped to `apps/phoenix` ·
**Source ref:** `4de8bf54833a5cf38d7f6eda06bf93525278a628` (clean Phoenix subtree) ·
**Execution policy:** sandboxed-source-and-local-only · **Result:** 0 confirmed,
9 needs_validation, 1 rejected.

## Files

| File | What it is |
|---|---|
| `REPORT.md` | Start here: run profile, posture summary, prioritized needs-validation table, hardening notes, coverage summary |
| `NEEDS-VALIDATION.md` | The nine leads with full traces, exact blockers, and safe validation plans |
| `FINDINGS-DETAIL.md` | Notes the empty confirmed set and points at the closest bounded evidence |
| `findings.json` | Structured records (schema-validated); the source of truth for traces/evidence/plans |
| `coverage-ledger.json` | 57 coverage units (47 covered, 10 candidate) with per-check evidence |
| `architecture.md` | The trust-boundary map the run hunted against |
| `run-metadata.json` | Run parameters and agent counts |
| `hardening-all.json` | 26 hardening notes collected across the waves |

The full working directory (hunter briefs, sandbox tooling, per-agent promoted
artifacts, verifier inputs/outputs) lives outside the repo at
`~/security-audit-skill/dhc-dashboard/run-1/` — re-run or extend the audit from
there. A future audit run must read this run's `coverage-ledger.json` and
`findings.json` as prior-run input and re-verify any lead whose source changed.

## Reading the results

- **No finding is "confirmed"** — every lead below still needs the exact owner
  observation or bounded local fixture named in its validation plan. None of
  them should be treated as a live vulnerability.
- The **rejected** record (`inventory.container-detail-item-location-disclosure`)
  is retained so future runs don't re-raise it: container detail is the
  documented ALE-106 member-readable API, not a missing control.
- Fingerprints are stable identifiers; keep them unchanged when re-verifying.
