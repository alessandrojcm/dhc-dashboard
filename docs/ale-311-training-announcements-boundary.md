# Training Announcements: module, API and dashboard boundary

**Status:** Decided (wayfinder grilling, 2026-09-21)  
**Ticket:** ALE-311 — part of the map *Specify dashboard-owned Discord Training notifications* (ALE-305)  
**Depends on:** ALE-308 (recurrence and exception semantics), ALE-309 (delivery protocol), ALE-310 (calendar workflow prototype)  
**ADR:** [0026](adr/0026-training-announcements-context-and-discord-protocol-seam.md)  
**Scope:** Where the Phoenix boundary sits, what `Dhc.Discord` keeps, the OpenAPI slices and dashboard capability, and how Workshop coupling is structurally prevented. Holiday ingestion/announcement progression (ALE-312), retention and operations (ALE-313), and cutover (ALE-314) are decided later and may amend this.

## Rename

The ALE-308 aggregate named **Training** is a schedule of Discord posts, not of practice, and operators must not read the new section as scheduling training sessions. The concept is renamed once, everywhere; earlier resolutions are read through this table.

| ALE-308 / ALE-309 term | Term from ALE-311 |
| --- | --- |
| Training | **Training Announcement** |
| Training Occurrence | **Announcement Occurrence** |
| Training Disablement / Suppression / Override | **Announcement Disablement / Suppression / Override** |
| Discord Training Delivery | **Discord Announcement Delivery** (also covers Holiday Announcements) |
| — | **Holiday Announcement** (day-before / same-day "no training" post) |

"Training" survives only as the plain-language word for what the club does on the night. Kinds stay `roll_call` and `sparring`.

## Phoenix: `Dhc.TrainingAnnouncements`

A new top-level context, sibling of `Dhc.WorkshopAnnouncements`, never a child of `Dhc.Workshops` or `Dhc.Discord`. Internal shape mirrors the Inventory split that has held (commands / pure policy / projection):

| Module | Owns | Never |
| --- | --- | --- |
| `Dhc.TrainingAnnouncements` | Facade. Actor-first commands: `create/2`, `update_schedule/3`, `update_copy/3`, `disable/2`, `enable/2`, `suppress/3`, `override/3`, `remove_suppression/3`, `remove_override/3`, `retire/2`, `delete/2`, `preview_copy/2`; reads for the API. `management_roles/0`. | Touch Oban directly; know Discord. |
| `Dhc.TrainingAnnouncements.Occurrences` | **Pure** projection: given an announcement, its exceptions, the holiday set and a date window, yields each occurrence with its resolved outcome and precedence chain (ALE-308 order). Shared by the worker, the read model and preview so they cannot disagree — the `LoanPolicy` analogue. | Hit the database. |
| `Dhc.TrainingAnnouncements.Copy` | **Pure** renderer: the ALE-309 token vocabulary, validation (unknown token, length limits, thread-name limit), the `@everyone` line. Used by preview and by delivery. | Post anything. |
| `Dhc.TrainingAnnouncements.Scheduling` | The **only** module that inserts or replaces the per-announcement Oban job. `replace_pending_job(multi, announcement)` uses Oban OSS `unique: [keys: [:announcement_id], states: [:available, :scheduled]]` + `replace: [scheduled: [:scheduled_at, :args]]` so the edit and the new job commit together; `cancel_pending_job/2` for disable/retire/delete. | Decide what to post. |
| `Dhc.TrainingAnnouncements.Delivery` | The Discord Announcement Delivery state machine from ALE-309: validate → freeze → `posting_message` (committed before the call) → `message_posted` → `creating_thread` → `delivered`, with `blocked` / `message_uncertain` / `thread_failed` / `skipped` / `missed`. Calls `Dhc.Discord` for transport and reads `Channels` for routing. | Repost, retarget, or reconcile. |
| `Dhc.TrainingAnnouncements.Channels` | Deployment routing `roll_call → DISCORD_ROLL_CALL_CHANNEL_ID`, `sparring → DISCORD_SPARRING_CHANNEL_ID`, holiday → `DISCORD_TRAINING_ANNOUNCEMENTS_CHANNEL_ID`. Each independently optional; `for_kind/1` returns `{:ok, id} | {:error, :unconfigured}`, which validation turns into `blocked` — boot never fails on a missing channel. | Fall back across kinds. |
| `Dhc.TrainingAnnouncements.Workers.AnnouncementWorker` | One self-perpetuating job per announcement on queue `training_announcements: 1`. Resolves, delivers/skips/misses, re-enqueues via `Scheduling`. | Be a discovery cron. |
| `Dhc.TrainingAnnouncements.HolidayAnnouncements` | Placement only: the day-before / same-day posts and their deliveries live here. Progression is ALE-312. | — |
| Schemas | `Announcement`, `AnnouncementSuppression`, `AnnouncementOverride`, `DiscordAnnouncementDelivery`. Tables `training_announcements`, `training_announcement_suppressions`, `training_announcement_overrides`, `discord_announcement_deliveries`. | Reference `club_activities`. |

Invariants live in the schema, not in locking: `EXCLUDE USING gist (announcement_id WITH =, daterange(from, to, '[]') WITH &&)` on overrides, `CHECK (start_time < end_time)` (same local date), unique `(announcement_id, occurrence_date)` on deliveries, `kind` immutable at the changeset. ALE-309's scale assumption stands: no `FOR UPDATE` ceremony.

### Time

Weekly schedules are Dublin civil time; jobs need the UTC instant per occurrence and the "still the same Dublin date" check. The app adds the **`tz`** dependency (compile-time database, no updater process) and promotes `Dhc.Inventory.ClubCalendar` to **`Dhc.ClubCalendar`**, moving `today/0` and `date_of/1` onto it in the same change and adding `to_utc/2` / `holiday_on/1`. One clock for Inventory and Training Announcements.

### Bank holidays

`Dhc.ClubCalendar` also owns the durable Irish bank-holiday cache and its refresh worker (contract: ALE-307; ingestion cadence and corrections: ALE-312). Training Announcements reads `holiday_on/1` and never queries holiday rows. Holiday *announcements* stay in Training Announcements because they are training posts.

## `Dhc.Discord` keeps the protocol, in both directions

- `Dhc.Discord.Adapter` (behaviour; Nostrum implementation + dev stub) grows two outbound calls:
  `create_message(channel_id, %{content, allowed_mentions, nonce})` and `create_thread_from_message(channel_id, message_id, %{name, auto_archive_duration})`.
- `Dhc.Discord` classifies transport failures into ALE-309's `{:retry | :blocked | :uncertain, %ApiError{}}` — that is HTTP/Discord knowledge. Delivery *state* stays in Training Announcements.
- Nothing else moves. Discord Doctor, Join Grants and the Workshop webhook worker (`Dhc.Discord.Worker`) are untouched; their placement is recorded debt.
- When a real bot arrives, inbound consumers (`Dhc.Discord.Gateway` / `Interactions`) translate events into calls on domain contexts — a "skip Sunday" slash command calls `Dhc.TrainingAnnouncements.suppress/3` exactly as the controller does. Discord owns no schedules, copy, routing or domain rows. No `Dhc.DiscordBot` context is created now.

## Authorization

`Dhc.TrainingAnnouncements.management_roles/0` → `~w(sparring_coordinator coach president admin committee_coordinator)`, used by one router pipeline `:training_announcements_admin_api`. No member-facing read: members see the Discord post.

## OpenAPI

One tag **`TrainingAnnouncements`** (`x-context: Dhc.TrainingAnnouncements`, `x-resource: Announcement`), one URL root `/training-announcements`, three slices (= three controllers per `mix gen.controllers`):

| Slice | Operations |
| --- | --- |
| `trainingAnnouncements` | `list`, `create`, `get`, `updateSchedule`, `updateCopy`, `disable`, `enable`, `retire`, `delete`, `previewCopy` (stateless `POST /training-announcements/preview`: kind, title, message, `@everyone`, a date → rendered message + thread name + validation errors) |
| `trainingAnnouncementExceptions` | suppressions and overrides under `/training-announcements/{id}/suppressions` and `/{id}/overrides`: `list*`, `create*`, `delete*` — shared dated-range validation, shared list shape |
| `trainingAnnouncementOccurrences` | the read model: `window` (`GET /training-announcements/occurrences?from=&to=`, Dublin dates, ≤ 62 days, **across all announcements**, includes holiday-announcement rows), `get` (`GET /training-announcements/{id}/occurrences/{date}` — inspector: outcome, precedence chain, rendered copy, delivery evidence), `listForAnnouncement` (`GET /training-announcements/{id}/occurrences?direction=upcoming|recent&limit=` — rail cards) |

Read-model rule: past dates come from delivery rows (evidence), future dates from `Occurrences.resolve/3`; the same function decides both, so the calendar can never disagree with what the worker will do. Exact evidence fields are ALE-313.

## Dashboard

- Capability **`training_announcements.manage`** in `capabilities.ts`, role set mirroring `management_roles/0`. No read/manage split.
- Nav entry **"Training Announcements"** → `/dashboard/training-announcements`; protected-route rule on `(dashboard)/training-announcements/**`. The three boundary tests (nav, routes, load) must agree, as for every capability.
- Components under `apps/web/src/lib/components/training-announcements/`; UI shape per ALE-310 Variant D.

## Workshop coupling is enforced

Phoenix, in `.reach.exs`:

```elixir
# deps: forbidden
{"Dhc.TrainingAnnouncements.*", ["Dhc.Workshops.*", "Dhc.WorkshopAnnouncements.*", "Dhc.Discord.Worker"]},
{"Dhc.Workshops.*", ["Dhc.TrainingAnnouncements.*"]},
# calls: forbidden — jobs are written in one place
{"Dhc.TrainingAnnouncements.*", ["Oban.insert", "Oban.insert!", "Oban.insert_all"],
 except: ["Dhc.TrainingAnnouncements.Scheduling"]}
```

Web, in the root Oxlint config: an override for `apps/web/src/routes/(dashboard)/training-announcements/**` and `apps/web/src/lib/components/training-announcements/**` with `no-restricted-imports` on `$lib/components/workshops/*`. The workshop calendar's `:global` CSS is extracted to a shared stylesheet (toolbar, weekday header, day cells, today ring, popup) *before* the Training Announcements calendar is built; event chips are not shared.

Storage: own tables only; nothing references `club_activities`.

## Oban

New queue `training_announcements: 1`. Concurrency 1 keeps the one-job-per-announcement model free of interleaving and separates it from the Workshop webhook `discord` queue in dashboards.

## Open for later tickets

- ALE-312: holiday refresh cadence, corrections, holiday-announcement scheduling and dedup (placement fixed here: `Dhc.ClubCalendar` facts, `Dhc.TrainingAnnouncements.HolidayAnnouncements` posts).
- ALE-313: which delivery evidence fields the occurrence read model exposes; retention.
- ALE-314: per-kind enablement order using the independent channel variables.
- Debt (out of this map): moving Discord Doctor and Join Grants out of `Dhc.Discord` into product contexts.
