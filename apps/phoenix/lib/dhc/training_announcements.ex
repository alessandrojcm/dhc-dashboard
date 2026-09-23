defmodule Dhc.TrainingAnnouncements do
  @moduledoc """
  Committee-managed, scheduled Discord announcements about club training
  (ALE-317, ADR 0026). Sibling of `Dhc.WorkshopAnnouncements`; never a child
  of `Dhc.Workshops` or `Dhc.Discord`, and nothing here references
  `club_activities`.

  ## Vocabulary (from `CONTEXT.md`, verbatim)

  * **Training Announcement** — a committee-managed, scheduled Discord
    announcement about club training, of exactly one kind — `roll_call` or
    `sparring` — that is either weekly recurring or one-off. Its schedule is
    expressed in Europe/Dublin civil time and follows Irish daylight-saving
    changes; it starts and ends on the same local date. Its scheduled time is
    the moment it is posted; there is no separate lead time. Its dated
    projection is an Announcement Occurrence. Its kind never changes;
    schedule, default title/message, and `@everyone` changes are prospective.
  * **Announcement Occurrence** — one local-date instance of a Training
    Announcement, identified by that announcement and its Europe/Dublin date.
  * **Discord Announcement Delivery** — the one durable Discord progression
    for an Announcement Occurrence or a Holiday Announcement, identified by
    what it announces and its Europe/Dublin date.
  * **Announcement Disablement** — a reversible, open-ended pause of one
    Training Announcement.
  * **Announcement Suppression** — a committee decision that prevents
    delivery for either one Announcement Occurrence or every occurrence of
    one weekly Training Announcement in a finite, inclusive range of
    Europe/Dublin dates.
  * **Announcement Override** — a replacement title, message, or both for one
    Announcement Occurrence or a finite, inclusive range of one weekly
    Training Announcement's Europe/Dublin dates.
  * **Holiday Announcement** — the day-before and same-day "no training"
    Discord post for an Irish bank holiday, delivered to a fixed announcement
    channel regardless of which Training Announcements the holiday suppresses.

  ## Shape

  Pure projection lives in `Dhc.TrainingAnnouncements.Occurrences` and pure
  copy rendering in `Dhc.TrainingAnnouncements.Copy`; both are database-free
  so the worker, the read model and preview cannot disagree. Actor-first
  facade commands (`create`, `update_schedule`, `disable`, `suppress`, …)
  arrive in ALE-323 — this skeleton owns the tables and the pure modules
  only. The only module that may write Oban jobs is the future
  `Dhc.TrainingAnnouncements.Scheduling`.
  """
end
