# Handoff: a later Batch re-offers a workshop someone already answered

## The problem

`Dhc.BeginnersWorkshops.BatchProposal` proposes **`waiting` people in priority
order, skipping only those with an *open* Intake** (`contacted` / `paid`). A
person whose Intake for a workshop ended in `declined`, `lapsed`, `returned`,
`withdrawn` or `no_show` therefore becomes eligible again — for the *same*
workshop — as soon as the next Batch is due. Nothing in the proposal knows
which workshop it is being asked about.

In production (2026-11-04) that put two people who had just declined the
28 Nov workshop into the very next Batch's lineup. Names, addresses and IDs
below are synthetic; the sequence of events is retained:

| # | Person | Waitlist entry | Intake for the workshop | Ended |
| --- | --- | --- | --- | --- |
| 2 | Person A `person-a@example.invalid` | `aaaaaaaa-0000-4000-8000-000000000001` | batch 2, `bbbbbbbb-0000-4000-8000-000000000001` | `declined` 4 Nov |
| 3 | Person B `person-b@example.invalid` | `aaaaaaaa-0000-4000-8000-000000000002` | batch 2, `bbbbbbbb-0000-4000-8000-000000000002` | `declined` 3 Nov |
| — | Person C `person-c@example.invalid` | `aaaaaaaa-0000-4000-8000-000000000003` | fast-track, `bbbbbbbb-0000-4000-8000-000000000003` | `declined` 28 Oct |

Workshop `cccccccc-0000-4000-8000-000000000001` (28 Nov 2026).
Person B's coordinator note says they cannot make this date and want to be
kept for the next one — the decline is their answer *about this date*, and the
queue is about to offer them the same date again. Of 191 currently eligible
`waiting` people, exactly these 3 would drop out under the rule below.

This is not a one-off: Batch 2 re-contacted three people who had declined
Batch 1 of the same workshop — Person D
(`aaaaaaaa-0000-4000-8000-000000000004`), Person E
(`aaaaaaaa-0000-4000-8000-000000000005`) and Person F
(`aaaaaaaa-0000-4000-8000-000000000006`). No test asserts that behaviour; it
falls out of the open-Intake-only rule.

## Agreed direction

A Batch for a workshop must skip anyone who already has **any Intake for that
workshop**, whatever its state. The person stays `waiting` and stays eligible
for a *different* workshop; they are simply not offered this one twice.

Keep two things as they are:

* the global "no open Intake" rule — one open Intake per person across all
  workshops, backed by the partial unique index
  `beginners_workshop_intakes_one_open_per_person_index`;
* `fast_track` and `FastTrackCandidates` — a coordinator deliberately placing
  someone who called back after declining is a real workflow, and both already
  skip only open Intakes. Say so in the module docs so the next reader does not
  "fix" the asymmetry.

## First code to read

Paths relative to `apps/phoenix`:

| Owner | Starting point |
| --- | --- |
| The rule | `lib/dhc/beginners_workshops/batch_proposal.ex`: `people/1`, `anyone_waiting?/0` (unused), private `eligible/0` |
| The pass | `lib/dhc/beginners_workshops/commands/batches.ex`: `lock_proposal/2` (~155), `still_the_proposal/3` (~195) — parity matters, both read the proposal |
| The preview | `lib/dhc/beginners_workshops/workshop_console.ex`: `next_batch/3` (~199) |
| States | `lib/dhc/beginners_workshops/intake.ex`: `@states`, `@open_states` |
| Standing | `lib/dhc/waitlist/waitlist_entry.ex` — `declined` does **not** move the Waitlist standing |
| Tests | `test/dhc/beginners_workshops/{batches,batches_concurrency,workshop_console,fast_track}_test.exs`, `test/dhc/beginners_workshops/carried_fees_test.exs:238`, `carried_fee_refunds_test.exs:274,554` |

Also read the automatic Batches row in `docs/agents/where-to-look.md` and the
`send_due_batch` moduledoc.

## Implementation sketch

1. `BatchProposal.people/2` taking the workshop id (put the id first if you
   prefer `people(workshop_id, size)`; the three call sites are
   `batches.ex:162`, `batches.ex:196`, `workshop_console.ex:206`).
2. Add to `eligible/1` beside the open-Intake `not exists`:

   ```elixir
   where: not exists(
     from(i in Intake,
       where: parent_as(:entry).id == i.waitlist_id and i.workshop_id == ^workshop_id,
       select: 1
     )
   )
   ```

3. Delete `anyone_waiting?/0` (no callers) rather than give it a workshop id.
4. `still_the_proposal/3` and the console preview must pass the same id, or the
   `:concurrent_change` retry and the preview stop agreeing.
5. No migration. `intakes` has an index on `workshop_id` and only a partial
   index on `waitlist_id`; a full `index(:beginners_workshop_intakes,
   [:waitlist_id])` is optional at this table size — measure before adding.

## Tests

* Proposal skips a person whose Intake for that workshop is `declined`, and
  still offers them for a second workshop.
* `WorkshopConsole` preview and `send_due_batch` both drop them and contact the
  next person in priority order (the parity test pattern already in
  `workshop_console_test.exs`).
* A `lapsed` Intake from the cutoff pass is likewise not re-offered.
* Update the two `BatchProposal.people(5)` calls in
  `fast_track_test.exs:150,154` (that test still passes: fast-track makes an
  *open* Intake).
* Then `mix test` on the files above, `mix precommit` from `apps/phoenix`.

## Open questions for the next session

1. **Reschedule.** A Workshop id survives `reschedule_workshop`, so a prior
   decliner stays excluded even though the date changed — the case Person B's note
   is literally about. Minimal fix accepts that. Re-opening on a reschedule
   would need the schedule generation recorded per Intake (new column), so keep
   it out of this change unless the user asks.
2. `no_show` / `attended` / `cancelled_refunded` / `withdrawn` are all covered
   by "any Intake"; that is intended, not incidental.
3. Anonymised Intakes have `waitlist_id = NULL`, so they never match.
4. `nobody_waiting` alerts will now fire in cases where the only remaining
   candidates had already been offered this workshop. Expected — it is the same
   message the sweep already sends.
5. No data repair: the three historical re-contacts are legitimate Intakes.
   Do not delete or rewrite them.

## How to reproduce the production read

The workshop ID in the example is synthetic. Substitute the workshop being
investigated in an authorized operator session.

`bin/dhc eval` dies on the machine (missing `fnox` env); use `rpc` with a piped
script — see "Inspecting production data on Fly" in
`docs/agents/commands.md`. The queries behind the tables above:

```sql
-- everyone currently eligible, and how many the new rule removes
with waiting as (
  select e.id from waitlist e
  join user_profiles p on p.waitlist_id = e.id
  where e.status = 'waiting' and e.email is not null
    and not exists (select 1 from beginners_workshop_intakes i
                    where i.waitlist_id = e.id and i.state in ('contacted','paid'))
)
select count(*),
       count(*) filter (where exists (
         select 1 from beginners_workshop_intakes i
         where i.waitlist_id = waiting.id
            and i.workshop_id = 'cccccccc-0000-4000-8000-000000000001'::uuid))
from waiting;
```

## Docs to update when it lands

* `AGENTS.md`, automatic Batches paragraph: eligibility is workshop-scoped.
* The automatic Batches row in `docs/agents/where-to-look.md`.
* `BatchProposal` moduledoc: the new skip rule, and why fast-track keeps the
  narrower one.
