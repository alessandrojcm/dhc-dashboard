# Shared Google Calendar credentials — implementation precedents

The agreed test seams are Auth's public interface, the existing Google adapters,
read-only diagnostics, and Workshop activation. This list accompanies code review.

| New file, function, type or test | Precedent |
| --- | --- |
| `test/dhc/google_calendar/auth_test.exs`, setup, “exchanges the one organizer grant…” | `test/dhc/workshop_calendar/google_test.exs`: Req.Test token exchange and restored application configuration |
| `lib/dhc/google_calendar/auth.ex` | Replaces OAuth implementations in `WorkshopCalendar.Google` and `TrainingCalendar.Google` |
| `Auth.error/0` type | Both Google adapters' existing closed error types |
| `Auth.access_token/0`, `Auth.token_response/1` | Both adapters' former `access_token/0`, `refresh/1`, `token_response/1`; error cases now distinguish client and grant failures |
| `Auth.validate_scopes/1` | Former `WorkshopCalendar.Google.valid_scope?/1`; validates the agreed combined grant as a set |
| `Auth.client_id/0` | Former adapter `credentials/0` and `WorkshopCalendar.Launch.configuration_issues/0`; returns only validated non-secret identity |
| `Auth.nonblank?/1` | `TrainingCalendar.Google.nonblank?/1`: reject empty or whitespace-only configuration |
| `Auth.check/0` | `WorkshopCalendar.Google.check_calendar/1`: reduce successful sensitive reads to `:ok` |
| Auth tests: “checks loaded credentials…”, “requires both scopes…”, “missing loaded credentials…”, “transport failures…” | Existing Google adapter OAuth/error/privacy tests, moved to their owning shared interface |
| `test/support/google_calendar_auth_config.ex`, `configure!/1` | `WorkshopCalendarTestConfig` plus adapter test setups: synthetic configuration and on-exit restoration |
| `GoogleCalendarAuthConfig.token/1` | Existing token-response literals in `WorkshopCalendarHTTP.route/2`; shared synthetic acknowledgment |
| `test/dhc/google_calendar/adapters_test.exs`, setup, “both adapters use the shared connection…” | Existing Google adapter Req.Test tests; covers both real adapters through their interfaces |
| `lib/dhc/google_calendar.ex`, `check/0`, `check_target/2` | `WorkshopCalendar.Google.check_calendar/1` and `TrainingCalendar.Google.list/1`; read-only orchestration with closed output |
| `test/dhc/google_calendar/check_test.exs`, setup | Adapter test setups with restored application configuration |
| Check tests: “checks loaded credentials…”, “a rejected client…”, “reports an inaccessible target…”, “missing target IDs…” | Adapter read-only calendar checks and existing missing-configuration tests; assert no mutation and no implicit primary target |
| `lib/mix/tasks/dhc.google_calendar.check.ex`, `run/1` | `dhc.workshop_calendar.preview` argument checking and safe JSON output; `Mix.Dhc.ReadOnlyRepo.run/1`'s cold `app.config` pattern, without Repo |
| `test/mix/tasks/dhc_google_calendar_check_test.exs`, setup | `dhc_workshop_calendar_test.exs`: restored process shell |
| Command tests: “prints only the safe report…”, “rejects arguments…”, “cold check never starts…” | Workshop Calendar task tests including cold `mix run --no-start` supervision check |
| Launch test: “shared connection identity remains activation-bound…” | Existing “a changed target configuration disables durable sending…” test, extended to shared credentials |
| `docs/google-calendar.md` | Existing provisioning and verification sections in both Calendar guides; shared operational owner |
| `docs/adr/0031-one-google-calendar-connection.md` | Existing numbered ADRs; records the approved permission-isolation trade-off |
| This precedent file | None — explicitly required by the implement skill for review handoff |

Existing Calendar tests retain their Req.Test surfaces, including concurrency and
reconciliation. Their credential setup and successful token fixtures now use the
shared synthetic connection. OAuth-only scope/privacy tests moved from the event
and ACL adapters to Auth; event/ACL behavior tests remain with their owners.

The `Auth.access_token/0` caller restriction follows `.reach.exs`'s existing
call restrictions for provider-specific transports.

## Review and verification

Reviewed task-owned changes against the pre-implementation working tree using
`but diff`, with this list as the Fit input. Root and Phoenix `AGENTS.md`,
`CONTEXT.md`, the Calendar guides, ADR 0031 and the repository's structure and
anti-pattern guidance supplied the standards. The conversation's approved
single-connection design supplied the spec. Build-review subagents were not
available, so these were three local review passes, not independent reviews.

- **Standards:** no remaining task-owned finding. Requests use Req, failures are
  closed, credentials stay out of diagnostics, and activation remains explicit.
- **Spec:** no remaining finding. One connection serves both transports;
  independent targets, enablement and ledgers remain unchanged. Production
  consent, secret writes and deployment were not performed.
- **Fit:** no remaining finding. OAuth-only tests moved to Auth; existing
  reconciliation, concurrency and controller tests use the shared synthetic
  connection. No generic credential registry or new dependency was introduced.

Verification: 206 focused Calendar tests and the final full Phoenix suite
(3,290 passed, 4 excluded); compilation with warnings-as-errors and Reach
architecture checks passed. `mix precommit` remains blocked by the existing
Credo nesting finding in `20261111090000_add_destination_place_provenance.exs`;
its audit also reports existing dependency advisories. Those are outside this
credential change.
