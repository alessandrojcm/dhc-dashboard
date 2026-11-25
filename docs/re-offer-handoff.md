# Handoff: Re-offer — an exception for someone who did not pay in time

## What the coordinator wants

A person was contacted for a Beginners' Workshop and did not pay by the
Payment Cutoff. Later, before the workshop takes place, they get in touch and
still want to come, and a seat is still free. The coordinator wants to find
them in that workshop's People roster, press **"Offer place again"**, and have
the normal offer flow run again for **that one person only**: the Contact
email, the Intake page, payment, Pre-workshop info.

The domain term is **Re-offer** (see `CONTEXT.md`). It is **not** Fast-track:
Fast-track lets someone skip the Waitlist, while a Re-offer makes an exception
for someone whose offer for this workshop already ran out. Never call it a
"re-invite": an **Invitation** is the membership invitation sent after
attendance (`Dhc.Onboarding.issue_invitation/3`), which is unrelated.

`CONTEXT.md` already contains the agreed wording. It changed **Fast-track**,
added **Re-offer**, and amended **Payment Cutoff** and **Payment Window**.
Treat it as the spec, and keep the code's moduledocs consistent with it.

## Decisions (settled with the owner — do not reopen)

1. **Eligible Intakes.** A Re-offer acts on an Intake for *this* workshop
   whose state is `lapsed` (unpaid at the cutoff with a seat free) **or**
   `returned` (unpaid at the cutoff with the workshop full). No other state,
   and never an Intake for another workshop.
2. **When.** Any time while the workshop is `scheduled` and before it starts,
   **including after the Payment Cutoff**. That is the whole point of the
   feature. It is refused once the workshop has started, been finalised or
   been cancelled.
3. **Seats.** A free seat is required (`WorkshopPolicy.seat_free?/2`: paid +
   live Seat Holds < capacity). **Overflow is out of scope**: staff who want
   to go over capacity raise it in Edit workshop first (`update_workshop`
   already allows that until finalisation). Do not add an overflow mode.
4. **A new Intake, not a reopened one.** The re-offer creates a new
   `contacted` Intake for the same workshop and person. The `lapsed` or
   `returned` Intake stays as it is in history. Do not add a backward
   transition out of `lapsed` or `returned`.
5. **Standing.** A lapsed person has standing `removed`, so a Re-offer puts
   them back to `waiting`. Reuse what Fast-track does (`Dhc.Waitlist.restore/2`
   inside the transaction). A returned person is already `waiting`. The
   3-month retention window cannot be an issue in practice, because lapses
   happen days before the workshop. Still go through `restorable?/2` rather
   than bypassing it.
6. **Paying after the cutoff.** The re-offered Intake may start payment
   until the workshop starts, even though payment is closed for everyone
   else. Its Payment Window (the date in `{{windowEnd}}`) is the workshop
   start. `WorkshopPolicy.payment_window_end/3` already returns that for a
   non-Batch Intake contacted after the cutoff, so it should need no change.
7. **Unpaid again.** The cutoff sweep must leave the re-offered Intake
   alone, as it already does for Carried Fee holders. If it is still
   `contacted` at Attendance Finalisation, finalisation settles it by the
   existing rule (`WorkshopPolicy.cutoff_settlement/3` → lapse or return),
   with no extra email.
8. **Reschedule.** The exception holds only while the Intake was contacted
   after the workshop's *current* cutoff. If a reschedule moves the cutoff
   past the Intake's `contacted_at`, it becomes an ordinary contacted
   Intake: it pays by the new cutoff, and the cutoff pass settles it normally.
   This should fall out of judging "contacted at or after the current cutoff",
   not out of a stored flag.
9. **Emails.** The same Contact email Batches and Fast-track send
   (`IntakeEmails.deliver/5` with `:contact`), with nothing new. A person who
   pays after the cutoff already gets Pre-workshop info inside
   `complete_payment`. Check that it still happens for this path.
10. **Who.** The same capability as Fast-track (the beginners coordinator and
    the managers), never assigned workshop Staff. Staff can add an optional
    note (≤ 500 characters), recorded on the Intake history row like other
    console commands.
11. **UI.** A row action, **"Offer place again"**, on the person's row in
    the workshop's People roster, one person at a time. It is shown only when
    Phoenix includes it in that row's `availableCommands`. The frontend never
    derives eligibility itself.
12. **One row per person.** After a Re-offer, the roster must not show the
    same name twice. Show the person's latest Intake for this workshop. The
    earlier `lapsed` or `returned` Intake is visible only in that row's
    history. **The report keeps counting Intakes** (so one person can be one
    lapse plus one later outcome). That is intended, so do not dedupe the
    report.

## Where things are today

All paths are under `apps/phoenix/lib/dhc/beginners_workshops/` unless noted.

- **Fast-track**: `commands/batches.ex`, `run({:staff, _}, {:fast_track, …})`.
  - `payment_open/3` refuses `:after_cutoff` unless the person holds a
    `held` Carried Fee.
  - `place_existing/2` restores a `removed` entry.
  - `no_open_intake/1` enforces one open Intake per person.
  - `contactable/1` requires an email and a first name.
  - The private `contact(workshop, origin, entry, reading)` (around line 342)
    creates the `contacted` Intake and queues the Contact email.

  A Re-offer should create its Intake through that same `contact/4`. If the
  command lives in another family, make `contact/4` a public `@doc false`
  function of `Commands.Batches` (or move it to a small named module) and call
  it qualified, never imported. AGENTS.md: "Do not add a second
  Intake-creation or Contact-email path."
- **Intake origin**: `intake.ex`, `@origins ~w(batch fast_track)`. Consider
  adding `re_offer`, so history, the report and the roster can tell the
  Intakes apart. Check for a database check constraint on `origin` and for
  report or console code that switches on origin.
- **The payment gate is workshop-wide**: `WorkshopPolicy.payment_open?/2`
  (workshop is scheduled and `now` is before the cutoff). It is used by:
  - `commands/payments.ex` `new_hold` → `:after_cutoff`. This is the gate the
    re-offered Intake must get past.
  - `intake_page.ex` (around line 165) → `:payment_closed`. The person's
    Intake page must show Pay for a re-offered Intake.
  - `commands/workshop_rules.ex` (around line 31).
  - `workshop_console.ex` `fast_track_open` and the line after it.
  - `fast_track_candidates.ex`.

  Add one **per-Intake** predicate in `WorkshopPolicy` (for example "may this
  Intake start payment now": workshop payment open, or a Re-offer contacted at
  or after the current cutoff while the workshop has not started). Use it in
  the payment and Intake-page paths. Leave the workshop-wide `payment_open?/2`
  unchanged for Batches, Fast-track and the console's workshop stage.
- **The cutoff sweep**: `commands/attendance.ex`, `pass_intake/2` for a
  `contacted` Intake. It skips Carried Fee holders (`pass.fee_holders`) and
  otherwise calls `settle_at_cutoff/2`. Re-offered Intakes need the same skip,
  judged by the rule in decision 8. Check the sweep's candidate filter in
  `run_due_passes/1` (`beginners_workshops.ex`): it runs for workshops that
  "still owe something" (a `contacted` Intake). Make sure a re-offered Intake
  does not make the pass run, and do nothing, on every 5-minute sweep forever,
  or accept that cost knowingly.
- **Finalisation** (`commands/attendance.ex`, `finalise_attendance` /
  `finish_workshop`) already settles every remaining `contacted` Intake by
  `cutoff_settlement/3`. It should need no change.
- **Console commands**: `intake_policy.ex` (`@commands`, `check/2`,
  `available_commands/1`, closed facts built only by `IntakePolicy.facts/1`)
  and `commands/intake_commands.ex` (`intake_command/6`: note, locked re-read,
  `check/2`, `act_on_intake/4`, one `IntakeEvent` row).

  The natural shape is an `IntakePolicy` command `:re_offer` on the
  lapsed/returned Intake, whose `act_on_intake/4` restores the standing if
  needed and calls the shared `contact/4`. The facts need a "seat free" bit
  and "workshop not started" (they may already carry the workshop status and
  time). Whatever you add to the facts must be selected in **both**
  `WorkshopConsole`'s roster SQL and `Commands.locked_intake_facts/3`.
  `policy_parity_test.exs` holds them equal. Do not default a fact on one
  side.

  Locks follow the boundary order: workshop → Waitlist entry → Intake (both
  the old and the new one, under the entry lock) → Carried Fee → payment.
  Re-judge everything under the locks. If the person has another open Intake
  anywhere, refuse it (`:open_intake`, the existing reason).
- **Capability**: the Fast-track capability is in `Commands`'
  `@staff_capabilities`. Give `re_offer` the same one, plus the
  `@families` dispatch entry if it gets its own command name.
- **HTTP**: name the new refusal reasons (for example `:no_seat`,
  `:workshop_started`, `:not_re_offerable`) in the Beginners' Workshop
  `*_http.ex` reason table. The `detail` text must pass
  `beginners_workshop_copy_test.exs`, which uses the backend-terms list in
  `tools/oxlint/anti-slop/shared/backend-terms.json`. Say "place", "payment
  deadline", "person", and never "Intake", "seat", "cutoff" or "re-offer".
- **OpenAPI and client**: add the command to the spec. Run
  `mise run api-gen` (it must stay idempotent) and regenerate
  `packages/api-client`.
- **Frontend**: the console roster is in
  `apps/web/src/routes/dashboard/beginners-workshop/workshops/[workshopId]/`
  (`workshop-console.svelte`, `console.remote.ts`). The status labels are in
  `apps/web/src/lib/beginners-workshops/console.ts` (`lapsed: "Payment deadline missed"`).
  Render the action from `availableCommands`, through the existing
  console-command dialog pattern with an optional note. Copy rules:
  `anti-slop/no-backend-terms-in-copy` and `copy-vocabulary.test.ts`. Use
  UI primitives from `#lib/components/ui` only.
- **Roster grouping (decision 12)**: `workshop_console.ex` `roster/2` and
  `roster_rows/2` currently build one row per Intake. Collapse the rows to the
  person's latest Intake for this workshop, and keep the earlier one reachable
  as history, without breaking the roster group counts (`rosterGroups`) or the
  `policy_parity_test.exs` facts.

## Tests to add (Phoenix)

Put these beside the existing suites (`apps/phoenix/test/dhc/beginners_workshops/`:
`fast_track_test.exs`, `payment_cutoff_test.exs`, `intake_payments_test.exs`,
`intake_commands_test.exs`, `reschedule_test.exs`, `policy_parity_test.exs`,
`report_test.exs`). Use `Clock.fixed/1`.

- Re-offer after the cutoff, for a `lapsed` Intake (standing restored to
  `waiting`) and for a `returned` one (standing untouched). The new Intake is
  `contacted`, Contact email queued with `{{windowEnd}}` = workshop start, and
  one history row with the note.
- Refusals: no free seat, workshop started, finalised or cancelled, the Intake
  is not `lapsed`/`returned`, an open Intake elsewhere, no email or profile,
  wrong capability or assigned Staff.
- The re-offered person can start payment after the cutoff; another
  contacted person in the same workshop still cannot.
- A run of the cutoff pass leaves the re-offered Intake `contacted`.
  Finalisation settles it (lapse with a seat free, return when full) and sends
  no email.
- Payment completed after the cutoff queues Pre-workshop info once.
- Reschedule with a later cutoff: the Intake becomes ordinary, payable until
  the new cutoff and settled by that cutoff's pass.
- The race for the last seat between a re-offered person and someone else
  ends with exactly one Seat Hold (the existing workshop-lock guarantee).
  Extend `intake_payments_concurrency_test.exs` if needed.
- Console: `availableCommands` lists `re_offer` exactly when the command
  would succeed, policy parity holds, and the roster shows one row per person.
  The report still counts both Intakes.

## Done means

- `mix precommit` is green in `apps/phoenix` (Credo, `reach.check --arch`,
  format, tests).
- The frontend workspace lint, typecheck and unit and browser tests are green.
  Add a browser test for the row action and its dialog.
- `mise run api-gen` produces only `skip` lines.
- The moduledocs touched (`Commands.Batches` or the owning family,
  `Attendance`'s cutoff pass, `WorkshopPolicy.payment_window_end/3`,
  `WorkshopConsole`, `IntakePolicy`) describe the Re-offer in the same words
  as `CONTEXT.md`. Add a row to `docs/agents/where-to-look.md`.

## Out of scope

- Overflow beyond capacity (parked by the owner).
- Re-offering Intakes that ended any other way (declined, withdrawn,
  no-show, deferred).
- Any change to Fast-track's own rules, Batches or the report's figures.
