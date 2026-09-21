# Training Announcements Is Its Own Context; Dhc.Discord Is a Protocol Seam

**Status:** Accepted  
**Date:** 2026-09-21  
**Tags:** training-announcements, discord, oban, boundaries, reach

## Context

The club posts roll-call and sparring announcements to Discord from a standalone Go bot (`dhc-discord-bot`): one process that owns the schedule (a Google Calendar), the copy, the bank-holiday logic, the dedup store, and the Discord transport. ALE-305 retires it and moves routine announcements into the dashboard. ALE-308 fixed the recurrence and exception semantics, ALE-309 the delivery protocol (one frozen delivery row per occurrence, one self-perpetuating Oban job per schedule, validate-then-freeze, no repost on ambiguity). ALE-311 had to decide *where* that lives.

Three homes were on the table:

1. **`Dhc.Workshops` / `club_activities`.** Trainings look like club activities with a date. But nothing Workshop has — capacity, pricing, registration, payment — applies, and the ALE-310 prototype showed the pull to reuse `workshop-calendar.svelte` is strong enough that coupling would happen by default.
2. **`Dhc.Discord`.** "It's the bot's job." That recreates the Go bot's shape — schedule, copy and transport in one module tree — which is the shape being retired. `Dhc.Discord` already blurs transport (`Adapter`) with two products (Doctor, Join Grants); a third product would make it the de-facto club-operations context.
3. **A new context.** Costs a tag, a URL root, a capability, new tables, and a set of Reach rules.

A second question hid inside the first: the aggregate ALE-308 called **Training** is, on inspection, a schedule of *posts* (ALE-309: "the calendar is a schedule of posts"). Operators must not read the new section as a place to schedule practice.

## Decision

**`Dhc.TrainingAnnouncements` is a new top-level context**, sibling of `Dhc.WorkshopAnnouncements`, and the aggregate is the **Training Announcement** (see `CONTEXT.md`). It owns schedules, exceptions, occurrence projection, copy rendering, the per-announcement Oban job, the Discord Announcement Delivery state machine, and the holiday announcements. It has its own tables and never reads or writes `club_activities`.

**`Dhc.Discord` is the protocol seam, in both directions.** Outbound today: `Dhc.Discord.Adapter` (Nostrum stays confined there by Reach) gains `create_message/2` and `create_thread_from_message/4` plus the classification of Discord/HTTP failures into ALE-309's `retry | blocked | uncertain`. Inbound later, when a real bot arrives: gateway/interaction consumers that translate events into calls on domain contexts (`Dhc.TrainingAnnouncements.suppress/3`, …). Discord modules own no schedules, copy, channel routing, or domain rows. Discord Doctor and Join Grants stay where they are for now; their placement is recorded debt, not part of this decision.

**Club-calendar facts are shared, not duplicated.** `Dhc.Inventory.ClubCalendar` becomes `Dhc.ClubCalendar`, owning "today in Europe/Dublin", civil-time ↔ UTC conversion, and the durable Irish bank-holiday cache with its refresh worker. Training Announcements reads `ClubCalendar.holiday_on/1`; it never queries holiday rows. To make civil-time projection pure and testable without Postgres, the app adds the `tz` time-zone database and moves `ClubCalendar` onto it.

**Coupling is enforced, not requested.** Reach forbids `Dhc.TrainingAnnouncements.* ↔ Dhc.Workshops.*`, `→ Dhc.WorkshopAnnouncements.*`, and `→ Dhc.Discord.Worker` (the Workshop webhook worker), and forbids `Oban.insert*` for announcement jobs outside `Dhc.TrainingAnnouncements.Scheduling`. On the web, an Oxlint `no-restricted-imports` override forbids `$lib/components/workshops/*` from the Training Announcements routes and components; the calendar visual language is extracted to a shared stylesheet first, and event chips stay domain-specific.

## Consequences

- One vocabulary end to end: `Dhc.TrainingAnnouncements`, tag `TrainingAnnouncements`, root `/api/training-announcements`, capability `training_announcements.manage`, nav "Training Announcements". ALE-308/309 texts are read with the rename table in `docs/ale-311-training-announcements-boundary.md`.
- Jobs are written in exactly one module, using Oban's `unique` + `replace` so a schedule edit swaps the pending job in the same commit as the edit. There is no per-minute discovery cron.
- Channel routing is deployment configuration read inside Training Announcements, per kind and independently optional; a missing channel blocks that kind at validate-time rather than failing boot, so the ALE-314 cutover can move one kind at a time.
- A future Discord bot has an obvious home and an obvious rule: it may *call* Training Announcements, it may not *be* it.
- Cost accepted: a new tag and capability, a `tz` dependency, and the `ClubCalendar` promotion touching six Inventory modules' aliases.

## Considered options

- **Keep `Training` as the code/API noun and rename only the UI.** Cheaper today; a permanent translation tax between what operators see and what the code says. Rejected.
- **A `Dhc.DiscordBot` context now, for the future inbound side.** Nothing inbound exists yet; premature. Rejected in favour of growing `Dhc.Discord` by direction when needed.
- **Keep asking Postgres for time-zone conversion** (`AT TIME ZONE`), as `ClubCalendar` does today. Works, but forces every projection through a DB round-trip and makes DST-edge unit tests need a database. Rejected; reversible.
