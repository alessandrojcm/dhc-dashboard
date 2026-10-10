defmodule Dhc.BeginnersWorkshops.Commands do
  @moduledoc """
  ALE-378 (ADR 0029 and its amendment): the one implementation of every
  Beginners' Workshop write. `Dhc.BeginnersWorkshops.execute/3` delegates
  here; nothing else in the context opens a write transaction. Staff
  commands, the person's Intake-page commands, Stripe-driven commands and
  time-driven passes all arrive as a `command` with an `actor`. The
  Stripe-facing Intake payment logic (ALE-381) is the internal
  `Dhc.BeginnersWorkshops.IntakeCheckout`, reached only through this
  boundary.

  ## The protocol

  Every command body runs as

      transact(fn ->
        with_locked(spec, fn locked ->
          reading = Clock.read(clock)   # the time, read under the lock
          decide from the locked rows (WorkshopPolicy, WorkshopFacts)
          write through persist/1 (and transition/3 for a status change)
        end)
      end)

  **Lock order is part of the contract: Beginners' Workshop → Waitlist entry
  → Intake → Carried Fee → payment → refund.** `with_locked/2` is the only
  function here that takes a row lock, and it walks `@lock_levels` in that
  order; a command may skip levels but can never lock upward, and a spec key
  outside the levels raises. A command that starts from a payment or refund
  (webhooks, the refund worker) will peek it unlocked, lock what it points to
  from the top down, re-read and retry if it moved (the ADR 0027 rule).

  **Stripe is called only between transactions**, with the result written
  after an authoritative re-read under the lock.

  **One transition table** (`@transitions`) declares every legal status
  change, and `transition/3` is the only writer of a status:

      Beginners' Workshop  scheduled → finalised | cancelled
      Intake               contacted → paid | lapsed | returned | declined
                           paid → attended | no_show | deferred
                           attended → no_show
                           no_show → attended | deferred
      payment (Seat Hold)  open → paid | releasing | released | policy_failed
                           releasing → released | paid
      refund               pending → processing | completed | failed
                           processing → completed | failed
      Carried Fee          held → applied | refunded | forfeited
                           applied → held | spent | refunded | forfeited
                           refunded → held (its Stripe refund failed)
                           spent → forfeited
                           forfeited → spent | held

  The workshop end states are terminal. Intakes are created `contacted`
  (ALE-380); ALE-381 adds `contacted → paid` and the payment rows; ALE-385
  adds the Payment Cutoff's `contacted → lapsed | returned`; ALE-391 adds
  Attendance Finalisation's `paid → attended | no_show`; ALE-386 adds
  `decline`'s `contacted → declined`; ALE-388 adds `defer`'s
  `paid → deferred` and the Carried Fee; ALE-393 adds the attendance
  corrections (`attended ↔ no_show`, `no_show → deferred`, and the Carried
  Fee's `spent ↔ forfeited`, `forfeited → held`). A Stripe refund
  is created `pending`; a manual refund is written `completed` (both by
  `persist/1`, the transition table governs every later change). Later
  Intake moves and Carried Fees join the table with the tickets that
  create them.

  **Constraints are translated, never raised.** `persist/1` declares every
  unique and check constraint and turns a violation into a domain reason or a
  field error.

  ## Actors

    * `{:staff, principal_id}` — authorized through `Dhc.Auth.Capabilities`
      for the command's capability **before any read**;
    * `{:intake_link, token}` — the person's Intake page;
    * `:stripe` — webhook and success-return completions;
    * `:system` — time-driven passes and workers.

  ## Clock

  `opts[:clock]` is a `Dhc.BeginnersWorkshops.Clock` (default: the wall
  clock). It is read inside the lock, so a decision never uses an instant
  taken before the rows were held. Tests pass `Clock.fixed/1`.

  ## Staff (ALE-379)

  `beginners_workshop_staff` rows are written only under the Beginners'
  Workshop lock (by `set_staff`, and `schedule_workshop` with optional
  Staff), so they need no lock level of their own. A Staff change notifies
  the people added and removed with keyed Notifications created inside the
  transaction (`Dhc.Notifications.create_keyed_in_transaction/3`) and
  signalled only after it commits.

  ## Automatic Batches (ALE-380)

  `send_due_batch` (`:system`, run by the periodic sweep) sends a workshop's
  next Batch only when `WorkshopPolicy.batch_due?/3` holds under the
  Beginners' Workshop lock and someone eligible is waiting. The Batch is the
  live `BatchProposal` of `WorkshopPolicy.batch_size/2` people; their
  Waitlist entries are locked and re-checked, and a person taken by a
  concurrent command makes the pass retry from a fresh proposal. Each new
  Intake queues "Contact – pay" through `IntakeEmails.queue/4` and writes an
  Intake Email log row in the same transaction, and the coordinator-alert
  holders get a keyed "Batch sent" Notification (signalled after commit).
  With free seats but nobody eligible waiting it sends one keyed
  Notification per workshop and nothing else. The Batch number's unique
  index and the Intake states keep a pass exactly-once.

  `pause_batches` / `resume_batches` stop and restart new Batches only.

  ## Reschedule (ALE-394)

  `reschedule_workshop` moves a scheduled workshop's date, start time
  and/or venue at any time before Attendance Finalisation; it is refused
  only with `:after_finalisation` or `:already_cancelled` (and a pending
  Batch never blocks it). Under the Beginners' Workshop lock, then the open
  Intakes:

    * the Payment Cutoff keeps its (Dublin civil) offset before the start
      unless a new date or time is supplied, and every open Batch window
      ending after the new cutoff is brought forward to it;
    * while Batch 1 has not gone out, the contact-from date keeps its offset
      before the workshop date unless one is supplied (`update_workshop`'s
      rules judge a supplied one); a kept date that would fall after the new
      cutoff date is brought forward to Dublin today, so Batch 1 goes out at
      the next 10:00;
    * "Workshop rescheduled" is queued to every open Intake (log occasion
      `rescheduled:<n>`); seats, holds and windows' people are untouched;
    * the workshop's `reschedule_count` names the reschedule: Pre-workshop
      info is owed once per schedule (occasion
      `IntakeEmailLog.pre_workshop_occasion/1`), so anyone who had it gets it
      again at the new cutoff through the same Payment Cutoff pass;
    * every Staff member except the actor gets a keyed Notification
      (`beginners-workshop:<id>:rescheduled:<n>`), signalled after commit.

  Nothing is scheduled per workshop, so no job needs rewriting.

  ## Cancel (ALE-395)

  `cancel_workshop` (`beginners.workshops.manage`, optional `reason` ≤ 500)
  cancels a scheduled workshop at any time before Attendance Finalisation
  (`:after_finalisation` / `:already_cancelled` otherwise). Under the
  Beginners' Workshop lock, then the open Intakes' Waitlist entries, the
  open Intakes, those people's live Carried Fees and the workshop's live
  Seat Holds and paying payments:

    * every `paid` Intake is deferred exactly as `defer` does it (a
      Stripe-paid one creates a `held` Carried Fee, a Carried-Fee-paid
      one's fee goes back to `held`), its door check-in is discarded, and
      "Workshop cancelled – paid" is queued instead of "Deferred";
    * every `contacted` Intake becomes `returned` (the person `waiting`
      with their original priority; a holder keeps their `held` fee), its
      live Seat Hold `releasing`, and "Workshop cancelled – unpaid" is
      queued — both with log occasion `cancelled`;
    * each Intake gets a `cancel_workshop` history row carrying the reason;
    * every Staff member except the actor gets the keyed Notification
      `beginners-workshop:<id>:cancelled`, signalled after commit.

  Every time-driven pass, the Intake page's commands and the door judge
  `status = scheduled`, so nothing happens to the workshop afterwards. A
  completion that arrives for a `releasing` hold is refunded in full by
  `complete_payment`'s `paid_after_close`. People move to another workshop
  by being fast-tracked there as Carried Fee holders, who then confirm.

  ## Fast-track (ALE-384)

  `fast_track` places one person straight into a workshop outside Batch
  order: a `waiting` Waitlist entry, a `removed` one within the 3-month
  retention window (restored to `waiting` through `Dhc.Waitlist.restore/2`)
  or a new person added through the staff path `Dhc.Waitlist.add_person/2`,
  all inside this transaction under the Beginners' Workshop lock and then the
  person's Waitlist entry lock. It is refused with `:open_intake`,
  `:not_eligible` (attended, invited or joined, or removed too long ago) and
  `:after_cutoff`, and the staff path's own refusals pass through. The new
  `contacted` Intake has origin `fast_track` and no Batch; its Contact email
  is the Batch one, with `{{windowEnd}}` rendering the Payment Cutoff. The
  person pays the workshop fee like everyone else.

  ## Door check-in (ALE-390)

  `check_in` / `undo_check_in` (`beginners.workshops.run`) record or clear
  who checked a `paid` Intake in at the door and when — never a walk-in, and
  only while `WorkshopPolicy.check_in_window/2` is `:open` (from 1 hour
  before the start on the workshop date until Attendance Finalisation or the
  end of that Dublin day). The capability is assignment-scoped, so the actor
  is authorized against the workshop's Staff **before any read** of the
  workshop or its Intakes (a denial is `:not_found`, concealing the
  workshop), and again under the Beginners' Workshop lock, which every
  Staff change takes. The record names a Principal, not a Staff row, so it
  stays when that person is later unassigned. Both are idempotent: checking
  in a checked-in person keeps the first record. Neither is a state change;
  Attendance Finalisation turns the record into `attended` / `no_show`.

  ## Console Intake commands (ALE-386)

  `decline`, `cancel_with_refund`, `withdraw`, `resend_link` and
  `rotate_link` (`beginners.workshops.manage`; `withdraw`
  `beginners.waitlist.manage`) act on one Intake of one workshop and share one plumbing,
  `intake_command/6`: every one takes an optional note, decides with
  `IntakePolicy.check/2` under the lock (the same rule the console's
  `availableCommands` comes from), and, when it acts, writes one Intake
  history row (`IntakeEvent`: command, actor, time, note) in the same
  transaction. A command whose Intake is already where it leads returns
  `ok` (`outcome: :already_done`) and writes nothing. Later Intake commands
  join `IntakePolicy` and add an `act_on_intake/4` clause.

    * `decline` locks Beginners' Workshop → the person's Waitlist entry →
      Intake → its live Seat Hold: the `contacted` Intake becomes
      `declined`, the person stays (or goes back to) `waiting` with their
      original priority, a live hold becomes `releasing` (Stripe still ends
      it; a completion that arrives anyway is refunded in full by
      `complete_payment`'s `paid_after_close` path) and "Declined" is
      queued.
    * `resend_link` sends the Intake's own email again — "Contact – pay"
      through the Batch path's `queue_contact_email/7` while `contacted`,
      "Place confirmed" while `paid` — with log occasion
      `resend_link:<event id>`. `rotate_link` first increments the link
      generation (a new token, so the old link resolves to nothing and the
      page says "no longer active"), then sends the same email
      (`rotate_link:<event id>`). Both work on open Intakes only.

    * `cancel_with_refund` (ALE-387) locks Beginners' Workshop → Waitlist
      entry → Intake → the payment that paid it: the Stripe-paid `paid`
      Intake becomes `cancelled_refunded` (its seat is free at once, since
      only `paid` Intakes and open holds count), a full refund of what that
      payment took is requested (`insert_refund/4`, the one refund-row
      writer, reason `cancelled_with_refund`, `requested_by` the actor), the
      person stays (or goes back to) `waiting` with their original priority,
      and "Cancelled with refund" is queued (occasion
      `cancelled_with_refund`).
    * `withdraw` (ALE-387, `beginners.waitlist.manage`) takes the same locks
      (the payment level is the live hold of a contacted Intake, the paying
      payment of a paid one). Contacted → `declined` (the hold becomes
      `releasing`), no email. Paid → `withdrawn`; `refund: true | false` is
      required (`:refund_choice_required`): a refund (reason `withdrawn`)
      with "Withdrawn – refunded", or a forfeit with "Withdrawn –
      forfeited" (occasion `withdrawn`). Either way the standing becomes
      `removed` through `Waitlist.change_standing/2`; `invited`/`joined`
      is `:already_invited`. The Waitlist tab's `{:withdraw, waitlist_id,
      attrs}` peeks the person's open Intake and runs exactly this under
      the lock (retrying if a Batch or Fast-track contacted them meanwhile),
      or, with none, only removes the standing. A Carried-Fee-paid Intake
      refunds or forfeits its Carried Fee instead (ALE-389).

  ## Carried Fees (ALE-388)

  A Carried Fee is a prepaid seat owned by the person (`CarriedFee`); a
  person holds at most one live one. It is created `held` by `defer` on a
  Stripe-paid Intake (pointing at that Intake's payment row) or by the
  Waitlist spreadsheet import (`import_carried_fee`, `:system`, inside the
  import row's transaction), and is read under the Carried Fee lock level.

    * `defer` (`beginners.workshops.manage`, a console Intake command) locks
      Beginners' Workshop → Waitlist entry → Intake → Carried Fee: the `paid`
      Intake becomes `deferred`, the person stays (or goes back to)
      `waiting` with their original priority, a Stripe-paid Intake creates
      a `held` Carried Fee and a Carried-Fee-paid one returns its fee to
      `held`, and "Deferred" is queued.
    * A holder of a `held` Carried Fee who is contacted (a Batch, a
      fast-track, a resent link) gets "Contact – confirm (Carried Fee)".
    * `confirm` (the person, `{:intake_link, token}`, or a console Intake
      command) moves a `contacted` Intake whose person holds a `held` fee
      to `paid` (`paid_via: carried_fee`) and the fee to `applied`, in one
      transaction with no Stripe call and no Seat Hold; it is refused with
      `:full` (the same seat rule as a hold) or `:no_carried_fee`. The
      Payment Cutoff does not stop it — the cutoff pass leaves a holder's
      `contacted` Intake open, and Attendance Finalisation settles it — so it
      is allowed until finalisation. "Place confirmed – Carried Fee" is
      queued, and Pre-workshop info too when the cutoff has passed.
    * `start_payment` is refused with `:confirm_instead` for a holder, and
      `fast_track` after the cutoff places holders only.
    * Attendance Finalisation spends an `applied` fee on an attended Intake
      and forfeits it on a no-show.

  ## Carried Fee refunds and forfeits (ALE-389)

  A Carried Fee refund is always the full amount originally paid, against
  the original payment, written by the one `insert_refund/4` with
  `carried_fee_id` set: a deferral's fee against its Intake payment row
  (`payment_id`), an imported fee against the Stripe PaymentIntent staff
  linked (no payment row; until linked it is `:payment_not_linked`). The fee
  becomes `refunded` when the refund is recorded and goes back to `held`
  when Stripe refuses it (`hold_fee_again/3`, in the same transaction as
  the refund's `failed`). Refund progression of such a refund locks the
  person's entry → Carried Fee → payment → refund.

    * `refund_carried_fee` (`beginners.workshops.manage`) — a console Intake
      command (`IntakePolicy`) on any unpaid Intake of a person with a
      `held` fee, or `{:refund_carried_fee, waitlist_id, attrs}` from the
      Waitlist tab, which runs the same on their open Intake or refunds the
      fee alone (the `withdraw_person` shape). Only someone `waiting` or
      `removed` within retention (`:fee_not_refundable`); a paid Intake is
      `:already_paid`. No Intake moves, standing and priority stay, and
      "Carried Fee refunded" is queued; a contacted Intake's page then asks
      for payment, and the next Contact email is "Contact – pay".
    * `cancel_with_refund` on a Carried-Fee-paid Intake refunds its fee;
      `withdraw` needs the refund-or-forfeit choice whenever the person
      holds a fee (paid, contacted, or with no Intake — even already
      removed), and forfeit makes it `forfeited`.
    * `retry_refund` / `record_manual_refund` follow a Carried Fee's failed
      refund too (the fee becomes `refunded` again), and
      `forfeit_carried_fee` — only for a Carried Fee's failed refund, while
      the fee is held — forfeits it. All three take a refund scope: a
      workshop id (its console) or `{:person, waitlist_id}` (the Waitlist
      tab). A fee confirmed or superseded since is no longer followed up.
    * `link_carried_fee_payment` reads an imported fee's PaymentIntent from
      Stripe between transactions (`IntakeRefunds.original_payment/1`: a
      `succeeded`, unrefunded payment) and records it with Stripe's amount
      under the entry → Carried Fee locks.

  No staff command sends email itself; `fast_track`'s Contact email is
  queued by the Intake it creates, exactly as a Batch's is.

  ## Intake payment (ALE-381)

  Seats taken = Intakes in `paid` + payment rows in `open` (Seat Holds);
  `WorkshopFacts` counts them and `WorkshopPolicy` judges them.

    * `start_payment` (`{:intake_link, token}`) is refused with
      `:after_cutoff` or `:full`. Otherwise it takes the Seat Hold under the
      Beginners' Workshop lock — an `open` payment row with the fee frozen
      and 30 minutes to run — and then, **between transactions**, creates the
      Checkout Session (`IntakeCheckout.create/2`, idempotency key
      `beginners-intake-payment:<id>`) and records it after re-reading the
      row under the lock. While a hold is live, pressing Pay again reuses its
      session. A hold whose 30 minutes ran out is `:payment_in_progress`
      until Stripe ends it. A session Stripe refused to create frees the hold
      at once (no session exists that could still be paid).
    * `complete_payment` (`:stripe`) runs from `checkout.session.completed`
      and from the success return (which passes the session id, so it is
      retrieved server-side). It is idempotent and always finds the row by
      session id. An amount or non-`eur` currency mismatch makes the row
      `policy_failed`, leaves the Intake `contacted` and requests the
      automatic refund (ALE-382). Otherwise the row becomes `paid`; an open
      Intake becomes `paid` (`paid_via: stripe`) and "Place confirmed –
      paid" is queued with its log row in the same transaction, while a
      completion for an Intake that already closed (or a `releasing` hold)
      requests the automatic refund instead.
    * `release_payment` (`:stripe`) runs on `checkout.session.expired`.
    * `reap_holds` (`:system`, a sweep pass) asks Stripe to expire every
      session whose hold ran out and settles the row from Stripe's answer
      (expired → released, completed → paid). Our clock alone never frees a
      seat.

  ## Payment Cutoff (ALE-385)

  `pass_payment_cutoff` (`:system`, a sweep pass) runs for a scheduled
  workshop at or after its Payment Cutoff. Under the Beginners' Workshop
  lock, then the contacted people's Waitlist entries, the open Intakes and
  the live Seat Holds, it queues "Pre-workshop info" to every `paid` Intake
  that has not had it (log occasion `pre_workshop`, unique per Intake) and
  settles every `contacted` Intake by `WorkshopPolicy.cutoff_settlement/3`:
  `lapsed` (standing `removed` through `Dhc.Waitlist.change_standing/2`)
  when seats were free, `returned` (standing left `waiting`, so the
  original priority stands) when the workshop was full, and left alone
  while its own Seat Hold is live — the cutoff stops only new holds, so a
  later sweep settles it once Stripe ends the hold. Neither close sends an
  email. An Intake that becomes `paid` after the cutoff gets Pre-workshop
  info in the same transaction (`complete_payment`). Re-running the pass
  finds nothing owed, so it is exactly-once.

  ## Attendance Finalisation and follow-up (ALE-391)

  `finish_workshop` (assigned Staff, `beginners.workshops.run`, from the
  door once check-in has opened) and `finalise_attendance` (`:system`, a
  sweep pass once the workshop's Dublin date has ended) are the one
  Attendance Finalisation. Under the Beginners' Workshop lock, then the
  open Intakes' Waitlist entries, the open Intakes and the live Seat Holds:
  every checked-in `paid` Intake becomes `attended` (standing `attended`)
  and every other `paid` Intake `no_show` (standing `removed`, no email);
  every Intake still `contacted` is settled by the Payment Cutoff rule
  (`WorkshopPolicy.cutoff_settlement/3`) — and while one has a live Seat
  Hold the workshop is not finalised yet (Finish is refused with
  `:payment_in_progress`; the pass waits for the next sweep). Check-in
  closes with the status change, and the Staff list is frozen: each row
  keeps the person's name as it was (`frozen_name`), and `set_staff`
  refuses a finalised workshop. The workshop records when, and who pressed
  Finish (nobody, for the pass).

  `send_follow_ups` (`:system`, a sweep pass) queues "Follow-up" once to
  every `attended` Intake from 10:00 Dublin the morning after
  (`WorkshopPolicy.follow_up_at/1`; log occasion `follow_up`, unique per
  Intake), so re-running it finds nothing owed.

  ## Attendance corrections (ALE-393)

  `correct_attendance` (`beginners.workshops.manage`, a console Intake
  command with `to`) fixes one Intake after Attendance Finalisation —
  `attended → no_show`, `no_show → attended`, or `no_show → deferred` for
  someone who told the club in time. It locks Beginners' Workshop → Waitlist
  entry → Intake → Carried Fee → the paying payment, and is refused with
  `:before_finalisation` (`:already_cancelled`), with `:already_invited`
  once the standing is `invited` or `joined`, and `:not_correctable`
  otherwise. The standing follows the lifecycle (attended → `attended`,
  no-show → `removed`, deferred → `waiting` with the original priority)
  through `Waitlist.change_standing/2`, and the Carried Fee that paid the
  Intake follows too (`spent`, `forfeited`, or `held` again on a deferral);
  a Stripe-paid no-show corrected to deferred gets a `held` Carried Fee on
  its payment, exactly as `defer` makes one, and "Deferred" is queued. A
  person corrected to attended once the Follow-up is due gets it at once
  (the same `queue_follow_up/3`); before then the sweep sends it. Other
  corrections email nobody.

  ## Hard delete: retention purge and manual delete (ALE-396)

  `delete_person` (`beginners.waitlist.manage`, the Waitlist tab's Delete)
  and `purge_retention` (`:system`, a sweep pass, one person per command)
  are the one hard delete. Under the person's Waitlist entry lock, then
  every Intake they ever had, then their live Carried Fee:

    * `delete_person` is refused with `:open_intake` and with
      `:not_deletable` (standing `invited` or `joined`, a claimed profile, or
      an Invitation that still names them); a Carried Fee needs the
      refund-or-forfeit choice first (`:refund_choice_required`), refunded in
      full against its original payment (reason `deleted`) or forfeited.
      It emails nobody.
    * `purge_retention` acts only on someone `removed` for more than the
      3-month retention window (`Waitlist.restorable?/2` on the boundary
      clock, under the lock) with no open Intake, and forfeits any `held`
      Carried Fee; anything else is `:not_due`.
    * Both anonymise the person's Intakes (`waitlist_id` null,
      `anonymised_at`), each keeping its queue date; an `attended` one first
      records `invitation_outcome` (`not_invited`, `invited`, `joined`).
      Every Carried Fee row of the person is kept with no link to them, and
      refund rows (which never named the person) stay. Then
      `Dhc.Waitlist.hard_delete/1` deletes the Guardian, the unclaimed
      UserProfile and the Waitlist entry.

  ## Invitation handoff (ALE-392)

  `invite` (`members.invite`) hands one attended person to Onboarding.
  Under the Beginners' Workshop lock, then the person's Waitlist entry and
  their Intake, it refuses unless the workshop is finalised
  (`:not_finalised`), the Intake is `attended` (`:not_attended`) and the
  standing is `attended` (`:already_invited`, `:already_joined`,
  `:not_invitable`; an anonymised person is `:person_not_found`). Then it
  issues the Invitation through `Dhc.Onboarding.issue_invitation/3` (with
  `waitlist_id:`, so acceptance claims this Waitlist profile) and moves the
  standing `attended → invited`, both in this transaction. Onboarding's own
  refusals come back as `:email_is_principal`,
  `:email_has_pending_invitation` and `:incomplete_details`, and are written
  to the Invitation processing log after the rollback. The Follow-up does not
  gate it. Onboarding never calls back: deleting the Invitation returns the
  standing to `attended` on the Onboarding side (`Dhc.Invitations`).

  A payment-started command peeks the row by session id without a lock,
  then locks Beginners' Workshop → Intake → payment from the top down and
  decides on the re-read row. The row's workshop and Intake never change,
  so the peek never goes stale.

  ## Refunds (ALE-382)

  A refund is always the full amount the payment row took, against that
  payment's PaymentIntent, under the idempotency key
  `beginners-intake-refund:<id>` (`IntakeRefunds`, the only Stripe refund
  caller). An automatic refund is requested inside the transaction that
  discovers it is owed — a `policy_failed` payment or a completion after
  the Intake closed — which also enqueues its submission and queues
  "Payment refunded (automatic)". A refund that starts a command peeks the
  row (its payment never changes), then locks payment → refund; refund
  progression never takes the workshop or Intake lock.

    * `submit_refund` (`:system`, the refund worker) calls Stripe between
      transactions and writes the answer after a locked re-read. A Stripe
      outage leaves it `pending` and fails (the job retries); a refusal
      makes it `failed`.
    * `apply_refund_event` (`:stripe`, `refund.*`) finds the row by Stripe
      refund id, or by the refund id in the object's metadata when the event
      beat the submission's record. Any other refund is acknowledged as not
      ours (the Workshops target owns it).
    * `reconcile` (`:system`, the reconcile worker) repairs missed events in
      one bounded pass: pending refunds are enqueued again, processing ones
      re-read from Stripe, and live or releasing payment rows settled when
      their Checkout Session completed or expired.
    * `retry_refund` and `record_manual_refund` (`beginners.workshops.manage`)
      follow up a failed refund with a new row (`follows_refund_id`); the
      failed row stays as history and a refund is followed up once.

  Terminal refunds (`completed`, `failed`) ignore later events. When a refund
  fails, the coordinator-alert holders get a keyed Notification
  (`beginners-workshop-refund:<id>:failed`, signalled after commit). Neither
  a failed refund nor a manual refund record emails the person.
  """

  import Ecto.Query

  alias Dhc.Auth
  alias Dhc.Auth.{Capabilities, Principal}

  alias Dhc.BeginnersWorkshops.{
    Batch,
    BatchProposal,
    BeginnersWorkshop,
    CarriedFee,
    Clock,
    Intake,
    IntakeCheckout,
    IntakeEmailLog,
    IntakeEmails,
    IntakeEvent,
    IntakeLink,
    IntakePayment,
    IntakePolicy,
    IntakeRefund,
    IntakeRefunds,
    StaffAssignment,
    WorkshopFacts,
    WorkshopPolicy,
    WorkshopProjection
  }

  alias Dhc.BeginnersWorkshops.IntakeEmails.Values
  alias Dhc.BeginnersWorkshops.Workers.RefundWorker
  alias Dhc.ClubCalendar
  alias Dhc.Notifications
  alias Dhc.Onboarding
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist
  alias Dhc.Waitlist.{Standing, WaitlistEntry}

  @type principal_id :: binary()

  @type actor ::
          {:staff, principal_id()}
          | {:intake_link, token :: String.t()}
          | :stripe
          | :system

  @typedoc """
  Schedule attributes use internal keys (string or atom): `venue`, `date`,
  `start_time`, `capacity`, `fee_cents`, and the optional
  `payment_cutoff_date`, `payment_cutoff_time` (Dublin civil; default the
  start time 3 days before), `contact_from` (default the Dublin day it is
  scheduled) and `payment_window_days` (default 7), plus optional Staff.
  Update attributes are any of `capacity`, `fee_cents`,
  `payment_cutoff_date`, `payment_cutoff_time`, `contact_from`,
  `payment_window_days`.

  Reschedule attributes are any of `venue`, `date`, `start_time`,
  `payment_cutoff_date`, `payment_cutoff_time` and `contact_from`; at least
  one of the date, start time and venue must change.

  Staff attributes (`set_staff`, and optional on a schedule) are
  `coach_principal_id` (`nil` for no coach) and `assistant_principal_ids`
  (a list). `set_staff` replaces the whole Staff list.
  """
  @type command ::
          {:schedule_workshop, [map()]}
          | {:update_workshop, workshop_id :: binary(), map()}
          | {:reschedule_workshop, workshop_id :: binary(), map()}
          | {:cancel_workshop, workshop_id :: binary(), map()}
          | {:pause_batches, workshop_id :: binary()}
          | {:resume_batches, workshop_id :: binary()}
          | {:send_due_batch, workshop_id :: binary()}
          | {:set_staff, workshop_id :: binary(), map()}
          | :start_payment
          | :confirm
          | {:import_carried_fee, waitlist_id :: binary(), paid_text :: String.t()}
          | {:complete_payment, session_id_or_object :: String.t() | map()}
          | {:release_payment, session_id_or_object :: String.t() | map()}
          | :reap_holds
          | {:pass_payment_cutoff, workshop_id :: binary()}
          | {:fast_track, workshop_id :: binary(), fast_track_person()}
          | {:submit_refund, refund_id :: binary()}
          | {:apply_refund_event, stripe_refund :: map()}
          | :reconcile
          | {:retry_refund, refund_scope(), refund_id :: binary()}
          | {:record_manual_refund, refund_scope(), refund_id :: binary(), map()}
          | {:forfeit_carried_fee, refund_scope(), refund_id :: binary()}
          | {:refund_carried_fee, waitlist_id :: binary(), map()}
          | {:link_carried_fee_payment, waitlist_id :: binary(), map()}
          | {:check_in, workshop_id :: binary(), intake_id :: binary()}
          | {:undo_check_in, workshop_id :: binary(), intake_id :: binary()}
          | {:finish_workshop, workshop_id :: binary()}
          | {:finalise_attendance, workshop_id :: binary()}
          | {:send_follow_ups, workshop_id :: binary()}
          | {:invite, workshop_id :: binary(), intake_id :: binary()}
          | {:delete_person, waitlist_id :: binary(), map()}
          | {:purge_retention, waitlist_id :: binary()}
          | {IntakePolicy.command(), workshop_id :: binary(), intake_id :: binary(), map()}

  @typedoc """
  Who `fast_track` places: an existing Waitlist entry by id, or a new
  person's registration details (the public registration body, string keys).
  """
  @type fast_track_person :: {:waitlist_entry, binary()} | {:new_person, map()}

  @typedoc """
  Where a failed refund is followed up from (ALE-389): a workshop's console
  (its id; the refund is about one of its Intakes) or a person's Waitlist
  entry (`{:person, waitlist_id}`; their Carried Fee's refund).
  """
  @type refund_scope :: binary() | {:person, binary()}

  @typedoc """
  A refusal. A failed `schedule_workshop` names the (0-based) workshop it
  failed on: `{:workshop, index, reason}`.
  """
  @type error ::
          :forbidden
          | :unknown_command
          | :not_found
          | :no_workshops
          | :too_many_workshops
          | :start_in_past
          | :invalid_payment_cutoff
          | :invalid_contact_from
          | :contact_from_locked
          | :fee_locked
          | :concurrent_change
          | :after_finalisation
          | :already_cancelled
          | :invalid_staff
          | :not_a_coach
          | :not_a_member
          | :staff_conflict
          | :capacity_below_taken
          | :after_cutoff
          | :full
          | :already_paid
          | :intake_closed
          | :payment_in_progress
          | :payment_unavailable
          | :session_not_recorded
          | :illegal_transition
          | :person_not_found
          | :open_intake
          | :not_eligible
          | :email_on_waitlist
          | :email_is_principal
          | :email_has_pending_invitation
          | :invalid_payload
          | :refund_not_found
          | :refund_not_failed
          | :refund_followed_up
          | :already_requested
          | :stripe_unavailable
          | :check_in_not_open
          | :check_in_closed
          | :not_paid
          | :not_due
          | :not_finalised
          | :not_attended
          | :already_invited
          | :already_joined
          | :not_invitable
          | :incomplete_details
          | :intake_not_found
          | :invalid_note
          | :intake_not_paid
          | :carried_fee_paid
          | :refund_choice_required
          | :invalid_refund_choice
          | :nothing_to_refund
          | :person_not_found
          | :no_carried_fee
          | :confirm_instead
          | :payment_not_found
          | :carried_fee_applied
          | :carried_fee_not_held
          | :not_a_carried_fee_refund
          | :payment_not_linked
          | :not_imported
          | :already_linked
          | :payment_already_linked
          | :invalid_payment_reference
          | :stripe_payment_not_found
          | :payment_not_succeeded
          | :payment_already_refunded
          | :fee_not_refundable
          | :invalid_reason
          | :before_finalisation
          | :not_correctable
          | :invalid_correction
          | :not_deletable
          | Ecto.Changeset.t()
          | {:workshop, non_neg_integer(), atom() | Ecto.Changeset.t()}

  # Command → the capability a staff actor needs. Every staff command is
  # listed; `authorize/2` refuses anything else before a read.
  @staff_capabilities %{
    schedule_workshop: :"beginners.workshops.manage",
    update_workshop: :"beginners.workshops.manage",
    reschedule_workshop: :"beginners.workshops.manage",
    cancel_workshop: :"beginners.workshops.manage",
    pause_batches: :"beginners.workshops.manage",
    resume_batches: :"beginners.workshops.manage",
    set_staff: :"beginners.workshops.manage",
    fast_track: :"beginners.workshops.manage",
    retry_refund: :"beginners.workshops.manage",
    record_manual_refund: :"beginners.workshops.manage",
    # Assignment-scoped (ALE-379): authorized against the workshop's Staff.
    check_in: :"beginners.workshops.run",
    undo_check_in: :"beginners.workshops.run",
    finish_workshop: :"beginners.workshops.run",
    # ALE-392: the Invitation handoff is an Invitation, so it needs the
    # Invitation capability (which the beginners coordinator holds).
    invite: :"members.invite",
    # Console Intake commands (ALE-386).
    decline: :"beginners.workshops.manage",
    # Carried Fees (ALE-388).
    defer: :"beginners.workshops.manage",
    confirm: :"beginners.workshops.manage",
    resend_link: :"beginners.workshops.manage",
    rotate_link: :"beginners.workshops.manage",
    # ALE-387. `withdraw` is the Waitlist's own exit, offered on the Waitlist
    # tab and the console, so it needs the Waitlist capability.
    cancel_with_refund: :"beginners.workshops.manage",
    withdraw: :"beginners.waitlist.manage",
    # Carried Fee refunds and forfeits (ALE-389): money, so the manager's.
    refund_carried_fee: :"beginners.workshops.manage",
    link_carried_fee_payment: :"beginners.workshops.manage",
    forfeit_carried_fee: :"beginners.workshops.manage",
    # ALE-393.
    correct_attendance: :"beginners.workshops.manage",
    # ALE-396: deleting a person is a Waitlist decision (the money choice is
    # the one `withdraw` already asks).
    delete_person: :"beginners.waitlist.manage"
  }

  # The console Intake commands: one plumbing, one rule (`IntakePolicy`).
  @intake_commands IntakePolicy.commands()

  # Commands only the `:system` actor (time-driven passes) may run.
  @system_commands [
    :send_due_batch,
    :reap_holds,
    :pass_payment_cutoff,
    :submit_refund,
    :reconcile,
    :finalise_attendance,
    :send_follow_ups,
    :import_carried_fee,
    :purge_retention
  ]

  # The person's Intake-page commands (`{:intake_link, token}`).
  @intake_link_commands [:start_payment, :confirm]

  # Stripe-driven commands (webhooks and the success return).
  @stripe_commands [:complete_payment, :release_payment, :apply_refund_event]

  # How many expired holds one `reap_holds` pass settles; the next sweep
  # takes the rest.
  @reap_batch 100

  @refund_outcomes %{"processing" => :processing, "completed" => :completed, "failed" => :failed}

  # How many refunds and payment rows one `reconcile` pass repairs (each);
  # the next tick takes the rest.
  @reconcile_batch 100

  # The coordinator-alert recipients (ALE-380).
  @alerts_capability :"beginners.workshops.alerts.receive"

  # A Batch pass that loses a proposed person to a concurrent command retries
  # from a fresh proposal this many times before giving up until the next
  # sweep.
  @batch_attempts 3

  @lock_levels [:workshop, :waitlist_entry, :intake, :carried_fee, :payment, :refund]

  @transitions %{
    workshop: %{"scheduled" => ~w(finalised cancelled)},
    intake: %{
      "contacted" => ~w(paid lapsed returned declined),
      "paid" => ~w(attended no_show deferred cancelled_refunded withdrawn),
      # Attendance corrections after finalisation (ALE-393).
      "attended" => ~w(no_show),
      "no_show" => ~w(attended deferred)
    },
    payment: %{
      "open" => ~w(paid releasing released policy_failed),
      "releasing" => ~w(released paid)
    },
    # Stripe may answer the create terminally, so `pending` can go straight
    # to `completed` or `failed`. A manual refund is inserted `completed`.
    refund: %{
      "pending" => ~w(processing completed failed),
      "processing" => ~w(completed failed)
    },
    # ALE-389: a fee is `refunded` once its refund is requested and goes
    # back to `held` if Stripe refuses that refund.
    carried_fee: %{
      "held" => ~w(applied refunded forfeited),
      "applied" => ~w(held spent refunded forfeited),
      "refunded" => ~w(held),
      # Attendance corrections (ALE-393) move a used fee to match.
      "spent" => ~w(forfeited),
      "forfeited" => ~w(spent held)
    }
  }

  # The status field of each entity in the transition table.
  @status_fields %{
    workshop: :status,
    intake: :state,
    payment: :status,
    refund: :status,
    carried_fee: :status
  }

  # One request plans a season, not a year of weekly sessions.
  @max_scheduled_at_once 20

  @schedule_types %{
    venue: :string,
    date: :date,
    start_time: :time,
    capacity: :integer,
    fee_cents: :integer,
    payment_cutoff_date: :date,
    payment_cutoff_time: :time,
    contact_from: :date,
    payment_window_days: :integer
  }

  @update_fields ~w(capacity fee_cents payment_cutoff_date payment_cutoff_time contact_from payment_window_days)a

  @reschedule_fields ~w(venue date start_time payment_cutoff_date payment_cutoff_time contact_from)a

  # Unique and check constraints, as the migrations named them, and what each
  # becomes. Unique constraints become a domain reason; check constraints
  # become a field error on the changeset (the changesets already enforce the
  # same shape, so these are the backstop for writers outside the seam).
  @unique_constraints %{
    BeginnersWorkshop => [],
    Batch => [{:number, "beginners_workshop_batches_number_index", :concurrent_change}],
    Intake => [
      {:waitlist_id, "beginners_workshop_intakes_one_open_per_person_index", :concurrent_change},
      {:link_token_hash, "beginners_workshop_intakes_link_token_hash_index", :concurrent_change}
    ],
    IntakeEmailLog => [
      {:occasion, "beginners_workshop_intake_emails_occasion_index", :concurrent_change}
    ],
    # Staff rows are written under the workshop lock, so these are backstops.
    StaffAssignment => [
      {:principal_id, "beginners_workshop_staff_workshop_principal_unique", :staff_conflict},
      {:workshop_id, "beginners_workshop_staff_one_coach", :staff_conflict}
    ],
    # Holds are taken under the Intake lock, so these are backstops.
    IntakePayment => [
      {:intake_id, "beginners_workshop_intake_payments_one_open_index", :concurrent_change},
      {:stripe_checkout_session_id, "beginners_workshop_intake_payments_session_index",
       :concurrent_change}
    ],
    # Refunds are written under the payment lock, so these are backstops.
    IntakeRefund => [
      {:payment_id, "beginners_workshop_intake_refunds_one_live_index", :already_requested},
      {:follows_refund_id, "beginners_workshop_intake_refunds_follows_index",
       :refund_followed_up},
      {:idempotency_key, "beginners_workshop_intake_refunds_idempotency_key_index",
       :concurrent_change},
      {:stripe_refund_id, "beginners_workshop_intake_refunds_stripe_refund_index",
       :concurrent_change},
      {:carried_fee_id, "beginners_workshop_intake_refunds_one_live_per_fee_index",
       :already_requested}
    ],
    # Carried Fees are written under the person's entry or Intake lock and
    # then the Carried Fee lock, so these are backstops.
    CarriedFee => [
      {:waitlist_id, "beginners_workshop_carried_fees_one_live_per_person_index",
       :concurrent_change},
      {:payment_id, "beginners_workshop_carried_fees_payment_index", :concurrent_change},
      {:stripe_payment_intent_id, "beginners_workshop_carried_fees_payment_intent_index",
       :payment_already_linked}
    ]
  }

  @check_constraints %{
    BeginnersWorkshop => [
      {:status, "beginners_workshops_status_check"},
      {:status, "beginners_workshops_finalised_check"},
      {:venue, "beginners_workshops_venue_check"},
      {:capacity, "beginners_workshops_capacity_check"},
      {:fee_cents, "beginners_workshops_fee_check"},
      {:payment_window_days, "beginners_workshops_payment_window_check"},
      {:reschedule_count, "beginners_workshops_reschedule_count_check"},
      {:status, "beginners_workshops_cancelled_check"},
      {:cancel_reason, "beginners_workshops_cancel_reason_check"}
    ],
    Batch => [
      {:number, "beginners_workshop_batches_number_check"},
      {:size, "beginners_workshop_batches_size_check"},
      {:window_ends_at, "beginners_workshop_batches_window_check"}
    ],
    Intake => [
      {:state, "beginners_workshop_intakes_state_check"},
      {:origin, "beginners_workshop_intakes_origin_check"},
      {:link_generation, "beginners_workshop_intakes_link_generation_check"},
      {:paid_via, "beginners_workshop_intakes_paid_via_check"},
      {:state, "beginners_workshop_intakes_paid_check"},
      {:checked_in_at, "beginners_workshop_intakes_check_in_check"},
      {:carried_fee_id, "beginners_workshop_intakes_carried_fee_check"},
      {:anonymised_at, "beginners_workshop_intakes_anonymised_check"},
      {:invitation_outcome, "beginners_workshop_intakes_invitation_outcome_check"}
    ],
    CarriedFee => [
      {:status, "beginners_workshop_carried_fees_status_check"},
      {:origin, "beginners_workshop_carried_fees_origin_check"},
      {:applied_intake_id, "beginners_workshop_carried_fees_applied_check"},
      {:amount_cents, "beginners_workshop_carried_fees_amount_check"},
      {:stripe_payment_intent_id, "beginners_workshop_carried_fees_link_check"}
    ],
    IntakePayment => [
      {:status, "beginners_workshop_intake_payments_status_check"},
      {:amount_cents, "beginners_workshop_intake_payments_amount_check"},
      {:currency, "beginners_workshop_intake_payments_currency_check"}
    ],
    StaffAssignment => [{:role, "beginners_workshop_staff_role_check"}],
    IntakeEvent => [
      {:note, "beginners_workshop_intake_events_note_check"},
      {:correction, "beginners_workshop_intake_events_correction_check"}
    ],
    IntakeRefund => [
      {:status, "beginners_workshop_intake_refunds_status_check"},
      {:method, "beginners_workshop_intake_refunds_method_check"},
      {:amount_cents, "beginners_workshop_intake_refunds_amount_check"},
      {:carried_fee_id, "beginners_workshop_intake_refunds_source_check"}
    ]
  }

  @doc """
  Executes one command as `actor`. The actor is authorized for the command
  before any read. Returns the command's closed view or a named refusal; a
  race never surfaces as an exception.
  """
  @spec execute(actor(), command(), keyword()) :: {:ok, term()} | {:error, error()}
  def execute(actor, command, opts \\ []) do
    with :ok <- authorize(actor, command) do
      run(actor, command, Clock.from_opts(opts))
    end
  end

  @doc "The transition table: entity → from status → legal target statuses."
  @spec transitions() :: %{atom() => %{String.t() => [String.t()]}}
  def transitions, do: @transitions

  @doc "Whether `from → to` is a legal status change for `entity`."
  @spec transition_allowed?(atom(), String.t(), String.t()) :: boolean()
  def transition_allowed?(entity, from, to),
    do: to in (@transitions |> Map.get(entity, %{}) |> Map.get(from, []))

  @doc "The lock levels, in the only order a command may take them."
  @spec lock_levels() :: [atom()]
  def lock_levels, do: @lock_levels

  @doc false
  # Constraint names `persist/1` translates; a test checks each one exists.
  @spec declared_constraints() :: [String.t()]
  def declared_constraints do
    for constraints <- [@unique_constraints, @check_constraints],
        {_schema, list} <- constraints,
        declared <- list,
        do: elem(declared, 1)
  end

  # ── Authorization ───────────────────────────────────────────────

  # `confirm` is both a console command and the person's own (ALE-388): the
  # Intake link actor takes the Intake-page path.
  defp authorize({:intake_link, _token} = actor, command) when command in @intake_link_commands,
    do: authorize_intake_link(actor)

  defp authorize(actor, command) do
    name = command_name(command)

    case Map.fetch(@staff_capabilities, name) do
      {:ok, capability} -> authorize_staff(actor, capability, command)
      :error when name in @system_commands -> authorize_system(actor)
      :error when name in @intake_link_commands -> authorize_intake_link(actor)
      :error when name in @stripe_commands -> authorize_stripe(actor)
      :error -> {:error, :unknown_command}
    end
  end

  defp authorize_system(:system), do: :ok
  defp authorize_system(_actor), do: {:error, :forbidden}

  # The link itself is the capability (ALE-374 "Intake link"): any
  # well-formed token may try; one that resolves to no Intake is `:not_found`.
  defp authorize_intake_link({:intake_link, token})
       when is_binary(token) and byte_size(token) in 1..128,
       do: :ok

  defp authorize_intake_link(_actor), do: {:error, :forbidden}

  defp authorize_stripe(:stripe), do: :ok
  defp authorize_stripe(_actor), do: {:error, :forbidden}

  defp authorize_staff({:staff, principal_id}, capability, command)
       when is_binary(principal_id) do
    if Capabilities.assignment_scoped?(capability),
      do: authorize_assigned(principal_id, capability, elem(command, 1)),
      else: authorize_role(principal_id, capability)
  end

  defp authorize_staff(_actor, _capability, _command), do: {:error, :forbidden}

  defp authorize_role(principal_id, capability) do
    with {:ok, id} <- Ecto.UUID.cast(principal_id),
         {:ok, projection} <- Auth.load_session_principal(%Principal{id: id}),
         :ok <- Capabilities.authorize(projection, capability) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  # An assignment-scoped capability is decided against the workshop's Staff
  # rows only — the resource, read before anything the capability protects.
  # A denial conceals the workshop (`:not_found`, the door view's 404).
  defp authorize_assigned(principal_id, capability, workshop_id) do
    with {:ok, id} <- Ecto.UUID.cast(principal_id),
         {:ok, workshop_id} <- Ecto.UUID.cast(workshop_id),
         {:ok, projection} <- Auth.load_session_principal(%Principal{id: id}) do
      case Capabilities.authorize(projection, capability, staff_resource(workshop_id)) do
        :ok -> :ok
        {:error, :not_found} -> {:error, :not_found}
        {:error, _denied} -> {:error, :forbidden}
      end
    else
      :error -> {:error, :not_found}
      _ -> {:error, :forbidden}
    end
  end

  defp staff_resource(workshop_id) do
    %{
      assigned_principal_ids:
        Repo.all(
          from(s in StaffAssignment, where: s.workshop_id == ^workshop_id, select: s.principal_id)
        )
    }
  end

  defp command_name(command) when is_tuple(command), do: elem(command, 0)
  defp command_name(command) when is_atom(command), do: command
  defp command_name(_command), do: nil

  # ── Commands ────────────────────────────────────────────────────

  defp run({:staff, principal_id}, {:schedule_workshop, list}, clock) when is_list(list) do
    cond do
      list == [] ->
        {:error, :no_workshops}

      length(list) > @max_scheduled_at_once ->
        {:error, :too_many_workshops}

      true ->
        # A new workshop has no row to lock yet; the clock is still read
        # inside the transaction that writes it.
        fn -> schedule_all(list, principal_id, Clock.read(clock)) end
        |> transact()
        |> signal_after_commit()
    end
  end

  defp run({:staff, _principal_id}, {:update_workshop, workshop_id, attrs}, clock)
       when is_map(attrs) do
    with {:ok, workshop_id} <- cast_id(workshop_id) do
      transact(fn ->
        with_locked(
          %{workshop: required(from(w in BeginnersWorkshop, where: w.id == ^workshop_id))},
          &update_locked(&1, attrs, clock)
        )
      end)
    end
  end

  defp run({:staff, principal_id}, {:reschedule_workshop, workshop_id, attrs}, clock)
       when is_map(attrs) do
    with {:ok, workshop_id} <- cast_id(workshop_id) do
      fn ->
        with_locked(
          %{
            workshop: required(from(w in BeginnersWorkshop, where: w.id == ^workshop_id)),
            intake: &open_intakes/1
          },
          &reschedule_locked(&1, attrs, principal_id, clock)
        )
      end
      |> transact()
      |> signal_after_commit()
    end
  end

  defp run({:staff, principal_id}, {:cancel_workshop, workshop_id, attrs}, clock)
       when is_map(attrs),
       do: cancel_workshop(principal_id, workshop_id, attrs, clock)

  defp run({:staff, principal_id}, {:pause_batches, workshop_id}, clock),
    do: set_batches_paused(workshop_id, principal_id, true, clock)

  defp run({:staff, principal_id}, {:resume_batches, workshop_id}, clock),
    do: set_batches_paused(workshop_id, principal_id, false, clock)

  defp run(:system, {:send_due_batch, workshop_id}, clock) do
    with {:ok, workshop_id} <- cast_id(workshop_id),
         do: send_due_batch(workshop_id, clock, @batch_attempts)
  end

  defp run({:staff, principal_id}, {:set_staff, workshop_id, attrs}, clock) when is_map(attrs) do
    with {:ok, workshop_id} <- cast_id(workshop_id),
         {:ok, staff} <- staff_input(attrs) do
      fn ->
        with_locked(
          %{workshop: required(from(w in BeginnersWorkshop, where: w.id == ^workshop_id))},
          &set_staff_locked(&1, staff, principal_id, clock)
        )
      end
      |> transact()
      |> signal_after_commit()
    end
  end

  defp run({:intake_link, token}, :start_payment, clock), do: start_payment(token, clock)

  defp run({:intake_link, token}, :confirm, clock), do: confirm_by_link(token, clock)

  defp run(:system, {:import_carried_fee, waitlist_id, paid_text}, clock)
       when is_binary(paid_text),
       do: import_carried_fee(waitlist_id, paid_text, clock)

  defp run(:stripe, {:complete_payment, session}, clock) do
    with {:ok, session} <- session_object(session), do: complete_payment(session, clock)
  end

  defp run(:stripe, {:release_payment, session}, clock) do
    with {:ok, session} <- session_object(session), do: release_payment(session, clock)
  end

  defp run(:system, :reap_holds, clock), do: reap_holds(clock)

  defp run(:system, {:pass_payment_cutoff, workshop_id}, clock) do
    with {:ok, workshop_id} <- cast_id(workshop_id) do
      transact(fn ->
        with_locked(
          %{
            workshop: required(from(w in BeginnersWorkshop, where: w.id == ^workshop_id)),
            waitlist_entry: &cutoff_entries(&1, clock),
            intake: &cutoff_intakes/1,
            carried_fee: &held_fees_of_contacted/1,
            payment: &cutoff_holds/1
          },
          &pass_cutoff_locked(&1, clock)
        )
      end)
    end
  end

  defp run({:staff, _principal_id}, {:fast_track, workshop_id, person}, clock) do
    with {:ok, workshop_id} <- cast_id(workshop_id),
         {:ok, person} <- fast_track_person(person) do
      transact(fn ->
        with_locked(
          %{
            workshop: required(from(w in BeginnersWorkshop, where: w.id == ^workshop_id)),
            waitlist_entry: fast_track_entry_query(person),
            carried_fee: fn
              %{waitlist_entry: %WaitlistEntry{id: id}} -> live_fee_query(id)
              _new_person -> nil
            end
          },
          &fast_track_locked(&1, person, clock)
        )
      end)
    end
  end

  defp run(:system, {:submit_refund, refund_id}, clock), do: submit_refund(refund_id, clock)

  defp run(:stripe, {:apply_refund_event, object}, clock) when is_map(object),
    do: apply_refund_event(object, clock)

  defp run(:system, :reconcile, clock), do: reconcile(clock)

  defp run({:staff, principal_id}, {:retry_refund, scope, refund_id}, clock),
    do: follow_up(scope, refund_id, principal_id, :retry, clock)

  defp run({:staff, principal_id}, {:record_manual_refund, scope, refund_id, attrs}, clock)
       when is_map(attrs) do
    with {:ok, note} <- manual_note(attrs),
         do: follow_up(scope, refund_id, principal_id, {:manual, note}, clock)
  end

  defp run({:staff, principal_id}, {:forfeit_carried_fee, scope, refund_id}, clock),
    do: follow_up(scope, refund_id, principal_id, :forfeit, clock)

  # ALE-389: the Waitlist tab's Refund Carried Fee names the person.
  defp run({:staff, principal_id}, {:refund_carried_fee, waitlist_id, attrs}, clock)
       when is_map(attrs),
       do: refund_person_fee(principal_id, waitlist_id, attrs, clock)

  defp run({:staff, _principal_id}, {:link_carried_fee_payment, waitlist_id, attrs}, clock)
       when is_map(attrs),
       do: link_fee_payment(waitlist_id, attrs, clock)

  defp run({:staff, principal_id}, {:check_in, workshop_id, intake_id}, clock),
    do: door_check_in(principal_id, workshop_id, intake_id, :check_in, clock)

  defp run({:staff, principal_id}, {:undo_check_in, workshop_id, intake_id}, clock),
    do: door_check_in(principal_id, workshop_id, intake_id, :undo, clock)

  defp run({:staff, principal_id}, {:finish_workshop, workshop_id}, clock),
    do: finalise(workshop_id, {:staff, principal_id}, clock)

  defp run(:system, {:finalise_attendance, workshop_id}, clock),
    do: finalise(workshop_id, :system, clock)

  defp run(:system, {:send_follow_ups, workshop_id}, clock) do
    with {:ok, workshop_id} <- cast_id(workshop_id) do
      transact(fn ->
        with_locked(
          %{
            workshop: required(from(w in BeginnersWorkshop, where: w.id == ^workshop_id)),
            intake: &follow_up_intakes(&1, clock)
          },
          &follow_ups_locked(&1, clock)
        )
      end)
    end
  end

  # Nothing about an Invitation depends on the time, so the clock is unused.
  defp run({:staff, principal_id}, {:invite, workshop_id, intake_id}, _clock) do
    with {:ok, workshop_id} <- cast_id(workshop_id),
         {:ok, intake_id} <- cast_id(intake_id) do
      intake = from(i in Intake, where: i.id == ^intake_id and i.workshop_id == ^workshop_id)

      fn ->
        with_locked(
          %{
            workshop: required(from(w in BeginnersWorkshop, where: w.id == ^workshop_id)),
            # An Intake's person never changes, so the unlocked read of its
            # `waitlist_id` cannot go stale.
            waitlist_entry:
              from(e in WaitlistEntry,
                where: e.id in subquery(select(intake, [i], i.waitlist_id))
              ),
            intake: required(intake)
          },
          &invite_locked(&1, principal_id)
        )
      end
      |> transact()
      |> record_invite_refusal(principal_id)
    end
  end

  # ALE-396: the Waitlist tab's Delete, and the sweep's retention purge.
  defp run({:staff, principal_id}, {:delete_person, waitlist_id, attrs}, clock)
       when is_map(attrs),
       do: delete_person(principal_id, waitlist_id, attrs, clock)

  defp run(:system, {:purge_retention, waitlist_id}, clock),
    do: purge_retention(waitlist_id, clock)

  # ALE-387: the Waitlist tab's withdraw names the person, not an Intake.
  defp run({:staff, principal_id}, {:withdraw, waitlist_id, attrs}, clock) when is_map(attrs),
    do: withdraw_person(principal_id, waitlist_id, attrs, clock)

  defp run({:staff, principal_id}, {command, workshop_id, intake_id, attrs}, clock)
       when command in @intake_commands and is_map(attrs),
       do: intake_command(command, principal_id, workshop_id, intake_id, attrs, clock)

  defp run(_actor, _command, _clock), do: {:error, :unknown_command}

  # ── schedule_workshop ───────────────────────────────────────────

  defp schedule_all(list, principal_id, reading) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, {[], []}}, fn {attrs, index}, {:ok, {views, created}} ->
      case schedule_one(attrs, principal_id, reading) do
        {:ok, {view, notifications}} -> {:cont, {:ok, {[view | views], created ++ notifications}}}
        {:error, reason} -> {:halt, {:error, {:workshop, index, reason}}}
      end
    end)
    |> case do
      {:ok, {views, created}} -> {:ok, {Enum.reverse(views), created}}
      error -> error
    end
  end

  defp schedule_one(attrs, principal_id, reading) when is_map(attrs) do
    input =
      {%{}, @schedule_types}
      |> Ecto.Changeset.cast(attrs, Map.keys(@schedule_types))
      |> Ecto.Changeset.validate_required([:venue, :date, :start_time, :capacity, :fee_cents])

    with {:ok, input} <- Ecto.Changeset.apply_action(input, :insert),
         {:ok, staff} <- staff_input(attrs),
         starts_at = WorkshopPolicy.starts_at(input),
         :ok <- in_future(starts_at, reading),
         cutoff = resolve_cutoff(input, input),
         :ok <- cutoff_before_start(cutoff, starts_at),
         contact_from = Map.get(input, :contact_from) || reading.today,
         :ok <- contact_from_on_or_before(contact_from, cutoff),
         {:ok, workshop} <-
           input
           |> Map.take([:venue, :date, :start_time, :capacity, :fee_cents])
           |> Map.merge(%{
             payment_cutoff: cutoff,
             contact_from: contact_from,
             payment_window_days:
               Map.get(input, :payment_window_days) ||
                 WorkshopPolicy.default_payment_window_days(),
             scheduled_by_principal_id: principal_id
           })
           |> BeginnersWorkshop.schedule_changeset()
           |> persist(),
         {:ok, created} <- apply_staff(workshop, [], staff, principal_id) do
      {:ok, {WorkshopProjection.view(workshop, facts_for(workshop), reading), created}}
    end
  end

  defp schedule_one(_attrs, _principal_id, _reading),
    do: {:error, Ecto.Changeset.change({%{}, @schedule_types})}

  # ── update_workshop ─────────────────────────────────────────────

  defp update_locked(%{workshop: workshop}, attrs, clock),
    do: update_settings(workshop, facts_for(workshop), attrs, Clock.read(clock))

  defp update_settings(%BeginnersWorkshop{status: "finalised"}, _facts, _attrs, _reading),
    do: {:error, :after_finalisation}

  defp update_settings(%BeginnersWorkshop{status: "cancelled"}, _facts, _attrs, _reading),
    do: {:error, :already_cancelled}

  defp update_settings(%BeginnersWorkshop{} = workshop, facts, attrs, reading) do
    current = %{
      capacity: workshop.capacity,
      fee_cents: workshop.fee_cents,
      payment_cutoff_date: ClubCalendar.on_date(workshop.payment_cutoff),
      payment_cutoff_time:
        workshop.payment_cutoff |> ClubCalendar.time_on() |> Time.truncate(:second),
      contact_from: workshop.contact_from,
      payment_window_days: workshop.payment_window_days
    }

    input =
      {current, Map.take(@schedule_types, @update_fields)}
      |> Ecto.Changeset.cast(attrs, @update_fields)

    with {:ok, next} <- Ecto.Changeset.apply_action(input, :update),
         :ok <- fee_change_allowed(input, facts),
         :ok <- capacity_change_allowed(input, next.capacity, facts),
         :ok <- contact_from_change_allowed(input, facts),
         cutoff = resolve_cutoff(next, workshop),
         :ok <- cutoff_before_start(cutoff, WorkshopPolicy.starts_at(workshop)),
         :ok <- contact_from_still_valid(next.contact_from, cutoff, facts),
         # Capacity may rise at any time before finalisation; lowering it
         # below the seats taken (paid + live holds) is refused. A new window length applies to Batches sent after it: a sent
         # Batch keeps its stored window end.
         {:ok, workshop} <-
           workshop
           |> BeginnersWorkshop.settings_changeset(%{
             capacity: next.capacity,
             fee_cents: next.fee_cents,
             payment_cutoff: cutoff,
             contact_from: next.contact_from,
             payment_window_days: next.payment_window_days
           })
           |> persist() do
      {:ok, WorkshopProjection.view(workshop, facts, reading)}
    end
  end

  # Seats taken are judged under the workshop lock every hold takes.
  defp capacity_change_allowed(input, capacity, facts) do
    if Ecto.Changeset.changed?(input, :capacity) and
         not WorkshopPolicy.capacity_allowed?(capacity, facts),
       do: {:error, :capacity_below_taken},
       else: :ok
  end

  # People contacted at one price are never charged another.
  defp fee_change_allowed(input, facts) do
    if Ecto.Changeset.changed?(input, :fee_cents) and not WorkshopPolicy.fee_editable?(facts),
      do: {:error, :fee_locked},
      else: :ok
  end

  defp contact_from_change_allowed(input, facts) do
    if Ecto.Changeset.changed?(input, :contact_from) and
         not WorkshopPolicy.contact_from_editable?(facts),
       do: {:error, :contact_from_locked},
       else: :ok
  end

  # Once Batch 1 has gone out the contact-from date has done its job, so a
  # later cutoff edit is not judged against it.
  defp contact_from_still_valid(contact_from, cutoff, facts) do
    if WorkshopPolicy.contact_from_editable?(facts),
      do: contact_from_on_or_before(contact_from, cutoff),
      else: :ok
  end

  # ── reschedule_workshop ─────────────────────────────────────────

  # Every open Intake of the workshop: each is told about the move.
  defp open_intakes(%{workshop: workshop}) do
    open = Intake.open_states()
    {:all, from(i in Intake, where: i.workshop_id == ^workshop.id and i.state in ^open)}
  end

  defp reschedule_locked(%{workshop: workshop, intake: intakes}, attrs, actor_id, clock) do
    reading = Clock.read(clock)

    with :ok <- still_scheduled(workshop),
         facts = facts_for(workshop),
         {:ok, input, next} <- reschedule_input(workshop, attrs),
         :ok <- moved_start_in_future(input, next, reading),
         cutoff = rescheduled_cutoff(workshop, next),
         :ok <- cutoff_before_start(cutoff, WorkshopPolicy.starts_at(next)),
         {:ok, contact_from} <-
           rescheduled_contact_from(workshop, input, next, cutoff, facts, reading),
         {:ok, workshop} <-
           workshop
           |> BeginnersWorkshop.reschedule_changeset(%{
             venue: next.venue,
             date: next.date,
             start_time: next.start_time,
             payment_cutoff: cutoff,
             contact_from: contact_from
           })
           |> persist(),
         :ok <- clamp_open_windows(workshop, reading),
         :ok <- tell_open_intakes(intakes, workshop, reading),
         {:ok, created} <- notify_rescheduled(workshop, actor_id) do
      {:ok, {WorkshopProjection.view(workshop, facts_for(workshop), reading), created}}
    end
  end

  # The new values over the current ones; at least one of the date, start
  # time and venue must change (otherwise there is nothing to tell anyone).
  defp reschedule_input(workshop, attrs) do
    current = %{
      venue: workshop.venue,
      date: workshop.date,
      start_time: workshop.start_time,
      payment_cutoff_date: nil,
      payment_cutoff_time: nil,
      contact_from: workshop.contact_from
    }

    input =
      {current, Map.take(@schedule_types, @reschedule_fields)}
      |> Ecto.Changeset.cast(attrs, @reschedule_fields)
      |> Ecto.Changeset.update_change(:venue, &String.trim/1)
      |> Ecto.Changeset.validate_required([:venue, :date, :start_time, :contact_from])
      |> Ecto.Changeset.validate_length(:venue, min: 1, max: BeginnersWorkshop.venue_max())
      |> require_a_move(workshop)

    with {:ok, next} <- Ecto.Changeset.apply_action(input, :update), do: {:ok, input, next}
  end

  defp require_a_move(input, workshop) do
    moved? =
      Enum.any?([:date, :start_time, :venue], fn field ->
        Ecto.Changeset.get_field(input, field) != Map.fetch!(workshop, field)
      end)

    if moved?,
      do: input,
      else: Ecto.Changeset.add_error(input, :date, "change the date, start time or venue")
  end

  # Only a new start is judged against the clock: a venue correction on the
  # day (or after it, before finalisation) still goes through.
  defp moved_start_in_future(input, next, reading) do
    if Ecto.Changeset.changed?(input, :date) or Ecto.Changeset.changed?(input, :start_time),
      do: in_future(WorkshopPolicy.starts_at(next), reading),
      else: :ok
  end

  # The cutoff keeps its Dublin civil offset before the start; a supplied
  # date or time replaces that half of the kept cutoff.
  defp rescheduled_cutoff(workshop, next) do
    kept = WorkshopPolicy.kept_offset_cutoff(workshop, next)

    ClubCalendar.to_utc(
      next.payment_cutoff_date || ClubCalendar.on_date(kept),
      next.payment_cutoff_time || kept |> ClubCalendar.time_on() |> Time.truncate(:second)
    )
  end

  # `update_workshop`'s rules judge a supplied contact-from date; a kept one
  # follows the workshop date, or comes forward to today when it would land
  # after the new cutoff date. Once Batch 1 has gone out it no longer
  # matters and stays as it was.
  defp rescheduled_contact_from(workshop, input, next, cutoff, facts, reading) do
    cond do
      not WorkshopPolicy.contact_from_editable?(facts) ->
        with :ok <- contact_from_change_allowed(input, facts), do: {:ok, workshop.contact_from}

      Ecto.Changeset.changed?(input, :contact_from) ->
        with :ok <- contact_from_still_valid(next.contact_from, cutoff, facts),
             do: {:ok, next.contact_from}

      true ->
        {:ok, WorkshopPolicy.kept_contact_from(workshop, next.date, cutoff, reading)}
    end
  end

  # Written under the workshop lock, which every Batch writer holds.
  defp clamp_open_windows(workshop, reading) do
    # A window can't end before it was sent: one past the new cutoff closes now.
    clamp_to = Enum.max([workshop.payment_cutoff, reading.now], DateTime)

    from(b in Batch,
      where:
        b.workshop_id == ^workshop.id and b.window_ends_at > ^reading.now and
          b.window_ends_at > ^clamp_to
    )
    |> Repo.all()
    |> Enum.reduce_while(:ok, fn batch, :ok ->
      case batch |> Batch.clamp_window_changeset(clamp_to) |> persist() do
        {:ok, _batch} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp tell_open_intakes(intakes, workshop, reading) do
    occasion = IntakeEmailLog.rescheduled_occasion(workshop.reschedule_count)

    values = fn first_name ->
      Map.put(
        base_values(workshop, first_name),
        "paymentCutoff",
        Values.deadline(workshop.payment_cutoff)
      )
    end

    Enum.reduce_while(intakes, :ok, fn intake, :ok ->
      case queue_intake_email(intake, "rescheduled", occasion, values, reading) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Assigned Staff stay assigned; each (bar the actor) hears about the move,
  # keyed by this reschedule so the next one notifies again.
  defp notify_rescheduled(workshop, actor_id) do
    key = "beginners-workshop:#{workshop.id}:rescheduled:#{workshop.reschedule_count}"
    body = "The Beginners' Workshop you're on has moved to #{when_where(workshop)}."

    workshop
    |> current_staff()
    |> Enum.map(& &1.principal_id)
    |> Enum.uniq()
    |> List.delete(actor_id)
    |> Enum.map(&{&1, key, body})
    |> create_keyed()
  end

  # ── cancel_workshop (ALE-395) ───────────────────────────────────

  defp cancel_workshop(principal_id, workshop_id, attrs, clock) do
    with {:ok, reason} <- cancel_reason(attrs),
         {:ok, workshop_id} <- cast_id(workshop_id) do
      fn ->
        with_locked(
          %{
            workshop: required(from(w in BeginnersWorkshop, where: w.id == ^workshop_id)),
            waitlist_entry: &cancel_entries/1,
            intake: &cancel_intakes/1,
            carried_fee: &cancel_fees/1,
            payment: &cancel_payments/1
          },
          &cancel_locked(&1, principal_id, reason, clock)
        )
      end
      |> transact()
      |> signal_after_commit()
    end
  end

  # Optional, at most a history note's length; blank is no reason.
  defp cancel_reason(attrs) do
    case fetch_attr(attrs, :reason) do
      nil ->
        {:ok, nil}

      reason when is_binary(reason) ->
        case reason |> String.trim() |> bounded_note() do
          {:ok, reason} -> {:ok, reason}
          {:error, :invalid_note} -> {:error, :invalid_reason}
        end

      _other ->
        {:error, :invalid_reason}
    end
  end

  # Every Intake is created and closed under the workshop lock, so its open
  # Intakes cannot change once it is held. Nothing more is locked when the
  # workshop is no longer scheduled.
  defp cancel_open_intakes(workshop),
    do:
      from(i in Intake,
        where: i.workshop_id == ^workshop.id and i.state in ^Intake.open_states()
      )

  defp cancel_entries(%{workshop: %BeginnersWorkshop{status: "scheduled"} = workshop}) do
    people = workshop |> cancel_open_intakes() |> select([i], i.waitlist_id)
    {:all, from(e in WaitlistEntry, where: e.id in subquery(people))}
  end

  defp cancel_entries(_locked), do: nil

  defp cancel_intakes(%{workshop: workshop, waitlist_entry: entries}) when is_list(entries),
    do: {:all, cancel_open_intakes(workshop)}

  defp cancel_intakes(_locked), do: nil

  # The live Carried Fees of the people with an open Intake: a
  # Carried-Fee-paid Intake's fee goes back to `held`, and a contacted
  # holder keeps theirs.
  defp cancel_fees(%{workshop: workshop, intake: intakes}) when is_list(intakes) do
    people = workshop |> cancel_open_intakes() |> select([i], i.waitlist_id)

    {:all,
     from(f in CarriedFee,
       where: f.waitlist_id in subquery(people) and f.status in ^CarriedFee.live_statuses()
     )}
  end

  defp cancel_fees(_locked), do: nil

  # The live Seat Holds (released) and the payments that paid the paid
  # Intakes (`paying_payment/1`'s rule: a deferral's Carried Fee points at
  # one).
  defp cancel_payments(%{workshop: workshop, intake: intakes}) when is_list(intakes) do
    paid = from(i in Intake, where: i.workshop_id == ^workshop.id and i.state == "paid")
    automatic = IntakeRefund.automatic_reasons()

    {:all,
     from(p in IntakePayment,
       as: :payment,
       where: p.workshop_id == ^workshop.id,
       where:
         p.status == "open" or
           (p.status == "paid" and p.intake_id in subquery(select(paid, [i], i.id)) and
              not exists(
                from(r in IntakeRefund,
                  where: r.payment_id == parent_as(:payment).id and r.reason in ^automatic
                )
              ))
     )}
  end

  defp cancel_payments(_locked), do: nil

  defp cancel_locked(%{workshop: workshop} = locked, actor_id, reason, clock) do
    reading = Clock.read(clock)

    with :ok <- still_scheduled(workshop),
         context = %{actor: actor_id, note: reason, options: %{}},
         {:ok, tally} <- cancel_all(locked, context, reading),
         {:ok, workshop} <-
           transition(
             :workshop,
             workshop,
             BeginnersWorkshop.cancel_changeset(workshop, actor_id, reason, reading.now)
           ),
         {:ok, created} <- notify_cancelled(workshop, actor_id) do
      view = WorkshopProjection.view(workshop, facts_for(workshop), reading)
      {:ok, {Map.merge(tally, %{workshop: view}), created}}
    end
  end

  defp cancel_all(locked, context, reading) do
    entries = Map.new(locked.waitlist_entry, &{&1.id, &1})
    fees = Map.new(locked.carried_fee, &{&1.waitlist_id, &1})
    payments = Enum.group_by(locked.payment, & &1.intake_id)

    Enum.reduce_while(
      locked.intake,
      {:ok, %{deferred: 0, returned: 0, released: 0}},
      fn intake, {:ok, tally} ->
        one = %{
          workshop: locked.workshop,
          waitlist_entry: Map.get(entries, intake.waitlist_id),
          intake: intake,
          carried_fee: Map.get(fees, intake.waitlist_id),
          payments: Map.get(payments, intake.id, [])
        }

        case cancel_intake(one, context, reading) do
          {:ok, counted} -> {:cont, {:ok, Map.merge(tally, counted, fn _k, a, b -> a + b end)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    )
  end

  # A paid person is deferred (story 129): their fee is carried, any door
  # check-in is discarded, and "Workshop cancelled – paid" replaces the
  # Deferred notice. A person whose Waitlist entry was deleted has nobody
  # to carry a fee to (and no address): their Intake just closes, and the
  # payment stays on record for a manual refund.
  defp cancel_intake(
         %{intake: %Intake{state: "paid", waitlist_id: nil} = intake},
         context,
         reading
       ) do
    with {:ok, intake} <- discard_check_in(intake),
         {:ok, intake} <-
           transition(:intake, intake, Intake.close_changeset(intake, "deferred")),
         {:ok, _event} <-
           record_intake_event(intake, :cancel_workshop, Ecto.UUID.generate(), context, reading),
         do: {:ok, %{deferred: 1}}
  end

  defp cancel_intake(%{intake: %Intake{state: "paid"} = intake} = one, context, reading) do
    payment =
      one.payments
      |> Enum.filter(&(&1.status == "paid"))
      |> Enum.min_by(&{DateTime.to_unix(&1.paid_at, :microsecond), &1.id}, fn -> nil end)

    with {:ok, intake} <- discard_check_in(intake),
         {:ok, intake} <-
           defer_paid(%{one | intake: intake} |> Map.put(:payment, payment), reading),
         :ok <- queue_cancelled(intake, one.workshop, "cancelled_paid", reading),
         {:ok, _event} <-
           record_intake_event(intake, :cancel_workshop, Ecto.UUID.generate(), context, reading),
         do: {:ok, %{deferred: 1}}
  end

  # An unpaid person never had a seat to lose: the Intake is `returned`,
  # the person `waiting` with their original priority, and a live Seat
  # Hold is `releasing` (Stripe still ends it; a completion that lands
  # anyway is refunded by `complete_payment`'s `paid_after_close`). A
  # Carried Fee holder keeps their `held` fee.
  defp cancel_intake(%{intake: %Intake{state: "contacted"} = intake} = one, context, reading) do
    holds = Enum.filter(one.payments, &(&1.status == "open"))

    with {:ok, intake} <-
           transition(:intake, intake, Intake.close_changeset(intake, "returned")),
         :ok <- Enum.reduce_while(holds, :ok, &release_each/2),
         :ok <- back_to_waiting(one.waitlist_entry),
         :ok <- queue_cancelled(intake, one.workshop, "cancelled_unpaid", reading),
         {:ok, _event} <-
           record_intake_event(intake, :cancel_workshop, Ecto.UUID.generate(), context, reading),
         do: {:ok, %{returned: 1, released: length(holds)}}
  end

  defp release_each(hold, :ok) do
    case release_to_stripe(hold) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp discard_check_in(%Intake{checked_in_at: nil} = intake), do: {:ok, intake}

  defp discard_check_in(%Intake{} = intake),
    do: intake |> Intake.undo_check_in_changeset() |> persist()

  defp queue_cancelled(intake, workshop, type, reading),
    do:
      queue_intake_email(
        intake,
        type,
        "cancelled",
        &%{"firstName" => &1, "date" => Values.date(workshop.date)},
        reading
      )

  # Assigned Staff stay on the (read-only) record; each but the actor hears
  # that it is off, once.
  defp notify_cancelled(workshop, actor_id) do
    key = "beginners-workshop:#{workshop.id}:cancelled"
    body = "The Beginners' Workshop on #{when_where(workshop)} has been cancelled."

    workshop
    |> current_staff()
    |> Enum.map(& &1.principal_id)
    |> Enum.uniq()
    |> List.delete(actor_id)
    |> Enum.map(&{&1, key, body})
    |> create_keyed()
  end

  # ── pause_batches / resume_batches ──────────────────────────────

  # Idempotent: pausing a paused workshop (or resuming a running one)
  # changes nothing and records nothing again.
  defp set_batches_paused(workshop_id, principal_id, paused?, clock) do
    with {:ok, workshop_id} <- cast_id(workshop_id) do
      transact(fn ->
        with_locked(
          %{workshop: required(from(w in BeginnersWorkshop, where: w.id == ^workshop_id))},
          &pause_locked(&1, principal_id, paused?, clock)
        )
      end)
    end
  end

  defp pause_locked(%{workshop: workshop}, principal_id, paused?, clock) do
    reading = Clock.read(clock)

    with :ok <- still_scheduled(workshop),
         {:ok, workshop} <- toggle_pause(workshop, principal_id, paused?, reading) do
      {:ok, WorkshopProjection.view(workshop, facts_for(workshop), reading)}
    end
  end

  defp toggle_pause(%BeginnersWorkshop{batches_paused: paused?} = workshop, _id, paused?, _r),
    do: {:ok, workshop}

  defp toggle_pause(workshop, principal_id, true, reading),
    do: workshop |> BeginnersWorkshop.pause_changeset(principal_id, reading.now) |> persist()

  defp toggle_pause(workshop, principal_id, false, reading),
    do: workshop |> BeginnersWorkshop.resume_changeset(principal_id, reading.now) |> persist()

  defp still_scheduled(%BeginnersWorkshop{status: "scheduled"}), do: :ok
  defp still_scheduled(%BeginnersWorkshop{status: "finalised"}), do: {:error, :after_finalisation}
  defp still_scheduled(%BeginnersWorkshop{status: "cancelled"}), do: {:error, :already_cancelled}

  # ── send_due_batch ──────────────────────────────────────────────

  defp send_due_batch(workshop_id, clock, attempts_left) do
    transact(fn ->
      with_locked(
        %{
          workshop: required(from(w in BeginnersWorkshop, where: w.id == ^workshop_id)),
          waitlist_entry: &lock_proposal(&1, clock)
        },
        &send_batch_locked(&1, clock)
      )
    end)
    |> case do
      {:ok, {outcome, notifications}} ->
        Enum.each(notifications, &Notifications.signal_created/1)
        {:ok, outcome}

      {:error, :concurrent_change} when attempts_left > 1 ->
        send_due_batch(workshop_id, clock, attempts_left - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Under the workshop lock: when a Batch is due, lock the proposed people's
  # Waitlist entries (in id order). Nothing is locked when it is not due.
  defp lock_proposal(%{workshop: workshop}, clock) do
    facts = facts_for(workshop)

    if WorkshopPolicy.batch_due?(workshop, facts, Clock.read(clock)) do
      ids =
        workshop
        |> WorkshopPolicy.batch_size(facts)
        |> BatchProposal.people()
        |> Enum.map(& &1.waitlist_id)

      {:all, from(e in WaitlistEntry, where: e.id in ^ids)}
    end
  end

  # The "no open window" rule and the rest of `batch_due?/3` are judged
  # again here, with the time read under the lock.
  defp send_batch_locked(%{workshop: workshop, waitlist_entry: entries}, clock) do
    reading = Clock.read(clock)
    facts = facts_for(workshop)

    cond do
      is_nil(entries) or not WorkshopPolicy.batch_due?(workshop, facts, reading) ->
        {:ok, {%{outcome: :not_due}, []}}

      entries == [] ->
        {:ok, {%{outcome: :nobody_waiting}, notify_nobody_waiting(workshop)}}

      true ->
        with {:ok, people} <- still_eligible(entries) do
          create_batch(workshop, facts, people, reading)
        end
    end
  end

  # A proposed person taken by a concurrent command (another workshop's
  # Batch, a fast-track) or no longer waiting: retry from a fresh proposal.
  defp still_eligible(entries) do
    ids = Enum.map(entries, & &1.id)

    if MapSet.new(BatchProposal.still_eligible(ids)) == MapSet.new(ids) do
      first_names =
        from(p in UserProfile,
          where: p.waitlist_id in ^ids,
          select: {p.waitlist_id, p.first_name}
        )
        |> Repo.all()
        |> Map.new()

      people =
        entries
        |> Enum.sort_by(&{DateTime.to_unix(&1.initial_registration_date, :microsecond), &1.id})
        |> Enum.map(&%{entry: &1, first_name: Map.get(first_names, &1.id) || ""})

      {:ok, people}
    else
      {:error, :concurrent_change}
    end
  end

  # ── fast_track ──────────────────────────────────────────────────

  defp fast_track_person({:waitlist_entry, id}) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, {:waitlist_entry, id}}
      :error -> {:error, :person_not_found}
    end
  end

  defp fast_track_person({:new_person, attrs}) when is_map(attrs), do: {:ok, {:new_person, attrs}}
  defp fast_track_person(_person), do: {:error, :invalid_payload}

  # An existing person's entry is locked after the workshop. A new person
  # has no entry yet: the staff path locks and inserts it under ours.
  defp fast_track_entry_query({:waitlist_entry, id}),
    do: from(e in WaitlistEntry, where: e.id == ^id)

  defp fast_track_entry_query({:new_person, _attrs}), do: nil

  defp fast_track_locked(%{workshop: workshop, waitlist_entry: entry} = locked, person, clock) do
    reading = Clock.read(clock)

    with :ok <- still_scheduled(workshop),
         :ok <- payment_open(workshop, locked.carried_fee, reading),
         {:ok, entry, placed} <- fast_track_entry(person, entry, reading),
         {:ok, first_name} <- contactable(entry),
         {:ok, intake} <-
           contact(
             workshop,
             :fast_track,
             entry,
             first_name,
             fast_track_window_end(workshop, reading),
             reading
           ) do
      {:ok, fast_track_view(intake, placed)}
    end
  end

  # After the cutoff only a holder of a `held` Carried Fee may be placed:
  # they confirm, so a late placement never needs a Stripe payment (story 38).
  defp payment_open(workshop, fee, reading) do
    if WorkshopPolicy.payment_open?(workshop, reading) or held?(fee),
      do: :ok,
      else: {:error, :after_cutoff}
  end

  # A holder placed after the cutoff may confirm until the workshop starts.
  defp fast_track_window_end(workshop, reading) do
    if WorkshopPolicy.payment_open?(workshop, reading),
      do: workshop.payment_cutoff,
      else: WorkshopPolicy.starts_at(workshop)
  end

  defp fast_track_entry({:waitlist_entry, _id}, nil, _reading), do: {:error, :person_not_found}

  defp fast_track_entry({:waitlist_entry, _id}, %WaitlistEntry{} = entry, reading) do
    with :ok <- no_open_intake(entry) do
      place_existing(entry, reading)
    end
  end

  defp fast_track_entry({:new_person, attrs}, nil, reading) do
    with {:ok, %{id: id}} <- Waitlist.add_person(attrs, now: reading.now) do
      {:ok, Repo.get!(WaitlistEntry, id), :added}
    end
  end

  defp place_existing(%WaitlistEntry{status: "waiting"} = entry, _reading),
    do: {:ok, entry, :waiting}

  # Checked here first so the restore (which runs in this transaction)
  # cannot refuse and leave it marked for rollback.
  defp place_existing(%WaitlistEntry{status: "removed", removed_at: %DateTime{}} = entry, reading) do
    if Waitlist.restorable?(entry.removed_at, reading.now) do
      with {:ok, _view} <- Waitlist.restore(entry.id, now: reading.now) do
        {:ok, Repo.get!(WaitlistEntry, entry.id), :restored}
      end
    else
      {:error, :not_eligible}
    end
  end

  defp place_existing(%WaitlistEntry{}, _reading), do: {:error, :not_eligible}

  # Read under the person's entry lock, which every Intake writer takes; the
  # one-open-Intake index is the backstop.
  defp no_open_intake(%WaitlistEntry{id: id}) do
    open = Intake.open_states()

    if Repo.exists?(from(i in Intake, where: i.waitlist_id == ^id and i.state in ^open)),
      do: {:error, :open_intake},
      else: :ok
  end

  # The Contact email is addressed by first name, so an anonymised person
  # (no email or profile) cannot be placed.
  defp contactable(%WaitlistEntry{email: nil}), do: {:error, :not_eligible}

  defp contactable(%WaitlistEntry{id: id}) do
    case Repo.one(from(p in UserProfile, where: p.waitlist_id == ^id, select: p.first_name)) do
      nil -> {:error, :not_eligible}
      first_name -> {:ok, first_name}
    end
  end

  defp fast_track_view(%Intake{} = intake, placed) do
    intake
    |> Map.take([:id, :workshop_id, :waitlist_id, :state, :origin, :contacted_at])
    |> Map.put(:placed, placed)
  end

  defp create_batch(workshop, facts, people, reading) do
    number = facts.batches_sent + 1
    window_end = WorkshopPolicy.window_end(workshop, reading)

    with {:ok, batch} <-
           %{
             workshop_id: workshop.id,
             number: number,
             size: length(people),
             sent_at: reading.now,
             window_ends_at: window_end
           }
           |> Batch.changeset()
           |> persist(),
         :ok <- contact_all(workshop, batch, people, reading) do
      {:ok, {%{outcome: :sent, batch: batch_view(batch)}, notify_batch_sent(workshop, batch)}}
    end
  end

  defp contact_all(workshop, batch, people, reading) do
    Enum.reduce_while(people, :ok, fn %{entry: entry, first_name: first_name}, :ok ->
      case contact(workshop, {:batch, batch}, entry, first_name, batch.window_ends_at, reading) do
        {:ok, _intake} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # One new `contacted` Intake, its "Contact – pay" email with the person's
  # own link, and the Intake Email log row — all in this transaction. A
  # Batch Intake's `{{windowEnd}}` is its Batch window; a fast-track's is the
  # Payment Cutoff.
  defp contact(workshop, origin, entry, first_name, window_end, reading) do
    intake_id = Ecto.UUID.generate()
    token = IntakeLink.token(intake_id, 1)

    {origin, batch_id} =
      case origin do
        {:batch, %Batch{id: batch_id}} -> {"batch", batch_id}
        :fast_track -> {"fast_track", nil}
      end

    with {:ok, intake} <-
           %{
             id: intake_id,
             workshop_id: workshop.id,
             waitlist_id: entry.id,
             origin: origin,
             batch_id: batch_id,
             queue_date: entry.initial_registration_date,
             link_token_hash: IntakeLink.hash(token),
             contacted_at: reading.now
           }
           |> Intake.contact_changeset()
           |> persist(),
         :ok <-
           queue_contact_email(
             intake,
             entry,
             first_name,
             workshop,
             window_end,
             "contact",
             reading
           ) do
      {:ok, intake}
    end
  end

  # The one Contact path: the Batch and Fast-track contact, and a resent or
  # rotated link (ALE-386), each with its own log occasion. The button is
  # the Intake's link at its current generation. A holder of a `held`
  # Carried Fee is asked to confirm, not to pay (ALE-388, story 60).
  defp queue_contact_email(intake, entry, first_name, workshop, window_end, occasion, reading) do
    token = IntakeLink.token(intake.id, intake.link_generation)

    {type, values} =
      if held_fee?(entry.id),
        do: {"contact_confirm", confirm_values(workshop, window_end, first_name)},
        else: {"contact_pay", contact_values(workshop, window_end, first_name)}

    with {:ok, _job} <-
           IntakeEmails.queue(type, entry, values, button_url: IntakeLink.url(token)),
         {:ok, _log} <-
           %{
             intake_id: intake.id,
             email_type: type,
             occasion: occasion,
             queued_at: reading.now
           }
           |> IntakeEmailLog.changeset()
           |> persist() do
      :ok
    end
  end

  defp contact_values(workshop, window_end, first_name) do
    %{
      "firstName" => first_name,
      "date" => Values.date(workshop.date),
      "startTime" => Values.start_time(workshop.start_time),
      "venue" => workshop.venue,
      "fee" => Values.money(workshop.fee_cents),
      "windowEnd" => Values.deadline(window_end),
      "paymentCutoff" => Values.deadline(workshop.payment_cutoff)
    }
  end

  defp confirm_values(workshop, window_end, first_name),
    do: workshop |> contact_values(window_end, first_name) |> Map.delete("fee")

  defp batch_view(%Batch{} = batch) do
    Map.take(batch, [:id, :workshop_id, :number, :size, :sent_at, :window_ends_at])
  end

  # Keyed Notifications to the coordinator-alert holders, inserted in this
  # transaction; the caller signals the created rows after commit.
  defp notify_batch_sent(workshop, batch) do
    alert(
      "beginners-workshop:#{workshop.id}:batch:#{batch.number}",
      "Batch #{batch.number} sent for the Beginners' Workshop on #{Values.date(workshop.date)}: " <>
        "#{batch.size} #{if batch.size == 1, do: "person", else: "people"} contacted."
    )
  end

  defp notify_nobody_waiting(workshop) do
    alert(
      "beginners-workshop:#{workshop.id}:nobody-waiting",
      "The Beginners' Workshop on #{Values.date(workshop.date)} has free seats, " <>
        "but nobody is left waiting on the Waitlist."
    )
  end

  defp alert(key, body) do
    @alerts_capability
    |> Capabilities.principal_ids_with()
    |> Enum.flat_map(fn principal_id ->
      case Notifications.create_keyed_in_transaction(principal_id, key, body) do
        {:ok, :created, notification} -> [notification]
        {:ok, :already_created} -> []
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # ── start_payment ───────────────────────────────────────────────

  defp start_payment(token, clock) do
    with {:ok, peek} <- peek_intake(token),
         {:ok, row} <- transact(fn -> hold_locked(peek, clock) end) do
      checkout(row, token, clock)
    end
  end

  defp hold_locked(peek, clock) do
    peek
    |> intake_spec(fn _locked -> open_payment(peek.intake_id) end)
    |> Map.put(:carried_fee, &locked_intake_fee/1)
    |> with_locked(&take_hold(&1, clock))
  end

  # The Intake a link resolves to (unlocked): only its stored hash matches.
  defp peek_intake(token) do
    hash = IntakeLink.hash(token)

    from(i in Intake,
      where: i.link_token_hash == ^hash,
      select: %{intake_id: i.id, workshop_id: i.workshop_id}
    )
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      peek -> {:ok, peek}
    end
  end

  defp intake_spec(%{workshop_id: workshop_id, intake_id: intake_id}, payment) do
    %{
      workshop: required(from(w in BeginnersWorkshop, where: w.id == ^workshop_id)),
      intake: required(from(i in Intake, where: i.id == ^intake_id)),
      payment: payment
    }
  end

  defp open_payment(intake_id),
    do: from(p in IntakePayment, where: p.intake_id == ^intake_id and p.status == "open")

  # Seats are judged under the workshop lock, which every hold takes, so N
  # people racing for the last seat get exactly one hold.
  defp take_hold(%{workshop: workshop, intake: intake, payment: open} = locked, clock) do
    reading = Clock.read(clock)

    cond do
      intake.state == "paid" -> {:error, :already_paid}
      intake.state != "contacted" or workshop.status != "scheduled" -> {:error, :intake_closed}
      # A Carried Fee holder is never asked for money twice (ALE-388).
      held?(locked.carried_fee) -> {:error, :confirm_instead}
      open != nil -> live_hold(open, reading)
      true -> new_hold(workshop, intake, reading)
    end
  end

  # Pressing Pay again reuses a live hold; one whose 30 minutes ran out
  # waits for Stripe to end its session.
  defp live_hold(open, reading) do
    if DateTime.compare(open.expires_at, reading.now) == :gt,
      do: {:ok, open},
      else: {:error, :payment_in_progress}
  end

  defp new_hold(workshop, intake, reading) do
    cond do
      not WorkshopPolicy.payment_open?(workshop, reading) ->
        {:error, :after_cutoff}

      not WorkshopPolicy.seat_free?(workshop, facts_for(workshop)) ->
        {:error, :full}

      true ->
        %{
          workshop_id: workshop.id,
          intake_id: intake.id,
          amount_cents: workshop.fee_cents,
          expires_at: WorkshopPolicy.hold_expires_at(reading)
        }
        |> IntakePayment.hold_changeset()
        |> persist()
    end
  end

  # Between transactions: reuse the live hold's session, or create it.
  defp checkout(%IntakePayment{checkout_url: url}, _token, _clock) when is_binary(url),
    do: {:ok, %{checkout_url: url}}

  defp checkout(%IntakePayment{} = row, token, clock) do
    case create_session(row, token, clock) do
      {:ok, %{url: url}} when is_binary(url) -> {:ok, %{checkout_url: url}}
      {:ok, _no_url} -> {:error, :payment_unavailable}
      {:error, _reason} -> {:error, :payment_unavailable}
    end
  end

  # Creates (or replays) the row's Checkout Session and records it. A
  # session Stripe refused to create cannot exist, so its hold is freed.
  defp create_session(%IntakePayment{} = row, token, clock) do
    case IntakeCheckout.create(row, checkout_person(row, token)) do
      {:ok, session} ->
        record_session(row, session)

      {:error, :rejected} ->
        _ = release_unsessioned(row, clock)
        {:error, :payment_unavailable}

      {:error, :retryable} ->
        {:error, :payment_unavailable}
    end
  end

  defp checkout_person(%IntakePayment{intake_id: intake_id, workshop_id: workshop_id}, token) do
    email =
      from(i in Intake,
        join: e in WaitlistEntry,
        on: e.id == i.waitlist_id,
        where: i.id == ^intake_id,
        select: e.email
      )
      |> Repo.one()

    date = Repo.one!(from(w in BeginnersWorkshop, where: w.id == ^workshop_id, select: w.date))
    %{token: token || intake_token(intake_id), email: email, date: date}
  end

  defp intake_token(intake_id) do
    generation =
      Repo.one!(from(i in Intake, where: i.id == ^intake_id, select: i.link_generation))

    IntakeLink.token(intake_id, generation)
  end

  # After an authoritative re-read: the session is recorded once; a
  # concurrent press that recorded it first wins (the idempotency key makes
  # it the same session).
  defp record_session(row, session),
    do: transact(fn -> with_locked(payment_spec(row), &record_session_locked(&1, session)) end)

  defp record_session_locked(%{payment: payment}, %{id: session_id, url: url}) do
    cond do
      payment.stripe_checkout_session_id == session_id ->
        {:ok, %{id: session_id, url: payment.checkout_url}}

      payment.status == "open" and is_nil(payment.stripe_checkout_session_id) ->
        with {:ok, payment} <-
               payment |> IntakePayment.session_changeset(session_id, url) |> persist(),
             do: {:ok, %{id: session_id, url: payment.checkout_url}}

      true ->
        {:error, :concurrent_change}
    end
  end

  defp release_unsessioned(row, clock),
    do: transact(fn -> with_locked(payment_spec(row), &release_unsessioned_locked(&1, clock)) end)

  defp release_unsessioned_locked(%{payment: payment}, clock) do
    if payment.status == "open" and is_nil(payment.stripe_checkout_session_id),
      do: release(payment, Clock.read(clock).now),
      else: {:ok, payment}
  end

  defp payment_spec(%{id: id, workshop_id: workshop_id, intake_id: intake_id}),
    do:
      intake_spec(
        %{workshop_id: workshop_id, intake_id: intake_id},
        required(from(p in IntakePayment, where: p.id == ^id))
      )

  defp release(payment, at),
    do:
      transition(
        :payment,
        payment,
        Ecto.Changeset.change(payment, status: "released", released_at: at)
      )

  # ── complete_payment / release_payment ──────────────────────────

  # A webhook passes the event's session object; the success return passes
  # only the id, so the session is retrieved server-side.
  defp session_object(%{"id" => id} = session) when is_binary(id), do: {:ok, session}

  defp session_object(id) when is_binary(id) and id != "" do
    case IntakeCheckout.retrieve(id) do
      {:ok, session} -> {:ok, session}
      {:error, :retryable} -> {:error, :payment_unavailable}
      {:error, :rejected} -> {:error, :not_found}
    end
  end

  defp session_object(_session), do: {:error, :not_found}

  defp peek_payment(session_id),
    do: Repo.one(from(p in IntakePayment, where: p.stripe_checkout_session_id == ^session_id))

  defp complete_payment(%{"id" => session_id} = session, clock) do
    case peek_payment(session_id) do
      nil ->
        # Ours but not recorded yet (the webhook beat `record_session`): fail
        # so the webhook retries; the reaper repairs it otherwise.
        if IntakeCheckout.ours?(session),
          do: {:error, :session_not_recorded},
          else: {:ok, %{outcome: :not_ours}}

      row ->
        transact(fn ->
          with_locked(payment_spec(row), &complete_locked(&1, session, clock))
        end)
    end
  end

  defp complete_locked(%{payment: payment} = locked, session, clock) do
    reading = Clock.read(clock)

    case {payment.status, IntakeCheckout.outcome(session)} do
      {status, _outcome} when status in ~w(paid policy_failed released) ->
        {:ok, %{outcome: :already_recorded}}

      {_status, {:complete, details}} ->
        if details.amount == payment.amount_cents and details.currency == payment.currency,
          do: record_paid(locked, details, reading),
          else: record_policy_failure(locked, details, reading)

      {_status, _not_paid} ->
        {:ok, %{outcome: :not_paid}}
    end
  end

  defp record_policy_failure(%{payment: payment} = locked, details, reading) do
    changeset =
      Ecto.Changeset.change(payment,
        status: "policy_failed",
        policy_failed_at: reading.now,
        amount_received_cents: details.amount,
        currency_received: details.currency,
        stripe_payment_intent_id: details.payment_intent
      )

    with {:ok, payment} <- transition(:payment, payment, changeset),
         {:ok, _refund} <-
           request_automatic_refund(%{locked | payment: payment}, "policy_failed", reading),
         do: {:ok, %{outcome: :policy_failed}}
  end

  defp record_paid(%{payment: payment, intake: intake, workshop: workshop}, details, reading) do
    was_open? = payment.status == "open"

    changeset =
      Ecto.Changeset.change(payment,
        status: "paid",
        paid_at: reading.now,
        amount_received_cents: details.amount,
        currency_received: details.currency,
        stripe_payment_intent_id: details.payment_intent
      )

    with {:ok, payment} <- transition(:payment, payment, changeset) do
      if was_open? and intake.state == "contacted",
        do: pay_intake(intake, workshop, reading),
        else: refund_after_close(%{payment: payment, intake: intake, workshop: workshop}, reading)
    end
  end

  # A completion for a hold whose Intake already closed (or that was
  # releasing): the payment is recorded and refunded in full at once.
  defp refund_after_close(locked, reading) do
    with {:ok, _refund} <- request_automatic_refund(locked, "paid_after_close", reading),
         do: {:ok, %{outcome: :paid_after_close}}
  end

  # A person paid after the Payment Cutoff gets Pre-workshop info at once
  # (story 49); before it, the cutoff pass sends it.
  defp pay_intake(intake, workshop, reading) do
    with {:ok, intake} <-
           transition(:intake, intake, Intake.paid_changeset(intake, "stripe", reading.now)),
         :ok <- queue_place_confirmed(intake, workshop, "place_confirmed", reading),
         :ok <- pre_workshop_if_cutoff_passed(intake, workshop, reading) do
      {:ok, %{outcome: :paid}}
    end
  end

  # "Place confirmed" for how the Intake was paid; `occasion` is
  # `place_confirmed` at payment, or a resent/rotated link's (ALE-386).
  defp queue_place_confirmed(
         %Intake{paid_via: "carried_fee"} = intake,
         workshop,
         occasion,
         reading
       ),
       do:
         queue_intake_email(
           intake,
           "place_confirmed_carried",
           occasion,
           &base_values(workshop, &1),
           reading
         )

  defp queue_place_confirmed(intake, workshop, occasion, reading) do
    queue_intake_email(
      intake,
      "place_confirmed_paid",
      occasion,
      &Map.put(base_values(workshop, &1), "fee", Values.money(workshop.fee_cents)),
      reading
    )
  end

  # Only a scheduled workshop past its cutoff: a cancelled or finalised one
  # sends no Pre-workshop info.
  defp pre_workshop_if_cutoff_passed(intake, workshop, reading) do
    if cutoff_due?(workshop, reading) do
      with {:ok, _queued_or_not} <- queue_pre_workshop(intake, workshop, reading), do: :ok
    else
      :ok
    end
  end

  # "Pre-workshop info", once per Intake per schedule: a reschedule
  # (ALE-394) moves the workshop to a new occasion, so it is owed again.
  # Every writer of it holds the workshop lock, so the log row read here
  # cannot appear concurrently; the unique `occasion` index is the backstop.
  # An anonymised person is owed nothing.
  defp queue_pre_workshop(%Intake{waitlist_id: nil}, _workshop, _reading), do: {:ok, :not_owed}

  defp queue_pre_workshop(intake, workshop, reading) do
    occasion = IntakeEmailLog.pre_workshop_occasion(workshop.reschedule_count)
    queue_once(intake, "pre_workshop", occasion, &base_values(workshop, &1), reading)
  end

  # Queues an Intake Email unless its occasion is already logged for the
  # Intake (the ledger is the schedule). Callers hold the workshop lock,
  # which every writer of these occasions takes.
  defp queue_once(intake, type, occasion, values, reading) do
    sent? =
      Repo.exists?(
        from(l in IntakeEmailLog, where: l.intake_id == ^intake.id and l.occasion == ^occasion)
      )

    if sent? do
      {:ok, :not_owed}
    else
      with :ok <- queue_intake_email(intake, type, occasion, values, reading), do: {:ok, :queued}
    end
  end

  defp base_values(workshop, first_name) do
    %{
      "firstName" => first_name,
      "date" => Values.date(workshop.date),
      "startTime" => Values.start_time(workshop.start_time),
      "venue" => workshop.venue
    }
  end

  # Queues one Intake Email to the Intake's person, with their Intake link as
  # the button, and writes its log row in the same transaction. An
  # anonymised person (no Waitlist entry) is not emailed.
  defp queue_intake_email(%Intake{waitlist_id: nil}, _type, _occasion, _values, _reading),
    do: :ok

  defp queue_intake_email(intake, type, occasion, values, reading) do
    entry = Repo.get!(WaitlistEntry, intake.waitlist_id)
    first_name = first_name_of(intake.waitlist_id)

    with {:ok, _job} <-
           IntakeEmails.queue(
             type,
             entry,
             values.(first_name),
             button_url: IntakeLink.url(IntakeLink.token(intake.id, intake.link_generation))
           ),
         {:ok, _log} <-
           %{intake_id: intake.id, email_type: type, occasion: occasion, queued_at: reading.now}
           |> IntakeEmailLog.changeset()
           |> persist() do
      :ok
    end
  end

  defp release_payment(%{"id" => session_id} = session, clock) do
    case {IntakeCheckout.outcome(session), peek_payment(session_id)} do
      {:expired, nil} ->
        # Not recorded (or not ours): the reaper settles an unrecorded hold.
        {:ok, %{outcome: :not_ours}}

      {:expired, row} ->
        transact(fn -> with_locked(payment_spec(row), &release_locked(&1, clock)) end)

      {_still_open_or_complete, _row} ->
        {:ok, %{outcome: :not_expired}}
    end
  end

  defp release_locked(%{payment: payment}, clock) do
    if payment.status in ~w(open releasing) do
      with {:ok, _payment} <- release(payment, Clock.read(clock).now),
           do: {:ok, %{outcome: :released}}
    else
      {:ok, %{outcome: :already_recorded}}
    end
  end

  # ── reap_holds ──────────────────────────────────────────────────

  # Holds whose 30 minutes ran out. Each is settled from Stripe's answer
  # through the same locked paths as the webhooks; a hold Stripe has not
  # ended stays open (and its seat taken) until the next pass.
  defp reap_holds(clock) do
    now = Clock.read(clock).now

    from(p in IntakePayment,
      where: p.status == "open" and p.expires_at <= ^now,
      order_by: [asc: p.expires_at, asc: p.id],
      limit: @reap_batch
    )
    |> Repo.all()
    |> Enum.reduce(%{released: 0, completed: 0, waiting: 0}, fn row, tally ->
      Map.update!(tally, reap(row, clock), &(&1 + 1))
    end)
    |> then(&{:ok, &1})
  end

  defp reap(%IntakePayment{stripe_checkout_session_id: nil} = row, clock) do
    # The session was never recorded: replaying the create either returns
    # the session Stripe made (then settle it) or proves none exists.
    case create_session(row, nil, clock) do
      {:ok, %{id: session_id}} -> reap_session(session_id, clock)
      {:error, _reason} -> if released?(row), do: :released, else: :waiting
    end
  end

  defp reap(%IntakePayment{stripe_checkout_session_id: session_id}, clock),
    do: reap_session(session_id, clock)

  defp reap_session(session_id, clock) do
    with {:error, _not_open} <- IntakeCheckout.expire(session_id),
         {:error, _unavailable} <- IntakeCheckout.retrieve(session_id) do
      :waiting
    else
      {:ok, session} -> settle(session, clock)
    end
  end

  defp settle(session, clock) do
    case IntakeCheckout.outcome(session) do
      :expired ->
        if match?({:ok, %{outcome: :released}}, release_payment(session, clock)),
          do: :released,
          else: :waiting

      {:complete, _details} ->
        if match?({:ok, _}, complete_payment(session, clock)), do: :completed, else: :waiting

      _open_or_unpaid ->
        :waiting
    end
  end

  defp released?(%IntakePayment{id: id}),
    do: Repo.exists?(from(p in IntakePayment, where: p.id == ^id and p.status == "released"))

  # ── Refunds ─────────────────────────────────────────────────────

  # Under the payment lock of the command that found the refund owed: the
  # refund row, its submission job and "Payment refunded (automatic)", all
  # in that transaction. A payment that took nothing has nothing to refund.
  defp request_automatic_refund(
         %{payment: payment, intake: intake, workshop: workshop},
         reason,
         reading
       ) do
    case insert_refund(payment, reason, nil, reading) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, refund} ->
        with :ok <- queue_payment_refunded(intake, workshop, refund, reading), do: {:ok, refund}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ALE-387: a refund a coordinator chose (`cancel_with_refund`, `withdraw`
  # with refund), under the lock of the payment that paid the Intake. The
  # command's own notice names the amount, so nothing else is emailed.
  # A paid Intake with no payment that took money has nothing to refund.
  defp request_staff_refund(%{payment: payment}, reason, %{actor: actor}, reading) do
    case payment && insert_refund(payment, reason, actor, reading) do
      {:ok, %IntakeRefund{} = refund} -> {:ok, refund}
      {:error, reason} -> {:error, reason}
      _nothing_taken -> {:error, :nothing_to_refund}
    end
  end

  # The full amount originally paid, against the original payment, and its
  # submission job — the one way a refund row is requested. The source is
  # a payment row (what it took, against its PaymentIntent), or (ALE-389) a
  # Carried Fee, `{:carried_fee, fee, payment, intake}`: what the fee's
  # original payment took — its payment row (`payment`, locked by the
  # caller) or, for an imported fee, the Stripe payment staff linked —
  # recorded against `intake`, the Intake the refund is about (else the
  # original payment's own Intake, else none).
  defp insert_refund(%IntakePayment{} = payment, reason, requested_by, reading) do
    case payment.amount_received_cents do
      amount when is_integer(amount) and amount > 0 ->
        write_refund(
          %{
            workshop_id: payment.workshop_id,
            intake_id: payment.intake_id,
            payment_id: payment.id,
            amount_cents: amount,
            currency: payment.currency_received || payment.currency,
            stripe_payment_intent_id: payment.stripe_payment_intent_id
          },
          reason,
          requested_by,
          reading
        )

      _nothing_taken ->
        {:ok, nil}
    end
  end

  defp insert_refund({:carried_fee, %CarriedFee{} = fee, payment, intake}, reason, by, reading) do
    if CarriedFee.refundable_through_stripe?(fee),
      do: write_refund(fee_refund_source(fee, payment, intake), reason, by, reading),
      else: {:error, :payment_not_linked}
  end

  # What a Carried Fee's refund is made against and recorded on.
  defp fee_refund_source(fee, payment, intake) do
    %{
      workshop_id: refund_workshop(intake, payment),
      intake_id: refund_intake(intake, payment),
      payment_id: fee.payment_id,
      carried_fee_id: fee.id,
      amount_cents: fee.amount_cents || payment_field(payment, :amount_received_cents),
      currency: fee.currency,
      stripe_payment_intent_id:
        fee.stripe_payment_intent_id || payment_field(payment, :stripe_payment_intent_id)
    }
  end

  defp refund_workshop(%Intake{workshop_id: id}, _payment), do: id
  defp refund_workshop(nil, payment), do: payment_field(payment, :workshop_id)
  defp refund_intake(%Intake{id: id}, _payment), do: id
  defp refund_intake(nil, payment), do: payment_field(payment, :intake_id)
  defp payment_field(nil, _field), do: nil
  defp payment_field(%IntakePayment{} = payment, field), do: Map.fetch!(payment, field)

  defp write_refund(source, reason, requested_by, reading) do
    with {:ok, refund} <-
           source
           |> Map.merge(%{
             reason: reason,
             requested_by_principal_id: requested_by,
             requested_at: reading.now
           })
           |> IntakeRefund.request_changeset()
           |> persist(),
         :ok <- enqueue_refund(refund.id) do
      {:ok, refund}
    end
  end

  defp queue_payment_refunded(%Intake{waitlist_id: nil}, _workshop, _refund, _reading), do: :ok

  defp queue_payment_refunded(intake, workshop, refund, reading) do
    case Repo.get(WaitlistEntry, intake.waitlist_id) do
      %WaitlistEntry{email: email} = entry when is_binary(email) ->
        with {:ok, _job} <-
               IntakeEmails.queue("payment_refunded", entry, %{
                 "firstName" => first_name_of(intake.waitlist_id),
                 "date" => Values.date(workshop.date),
                 "refundAmount" => refund_amount(refund)
               }),
             {:ok, _log} <-
               %{
                 intake_id: intake.id,
                 email_type: "payment_refunded",
                 occasion: "payment_refunded:#{refund.payment_id}",
                 queued_at: reading.now
               }
               |> IntakeEmailLog.changeset()
               |> persist() do
          :ok
        end

      _anonymised ->
        :ok
    end
  end

  defp first_name_of(waitlist_id) do
    Repo.one(
      from(p in UserProfile, where: p.waitlist_id == ^waitlist_id, limit: 1, select: p.first_name)
    ) || ""
  end

  defp refund_amount(%IntakeRefund{amount_cents: cents, currency: "eur"}), do: Values.money(cents)

  defp refund_amount(%IntakeRefund{amount_cents: cents, currency: currency}),
    do:
      "#{div(cents, 100)}.#{cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")} " <>
        String.upcase(currency)

  defp enqueue_refund(refund_id) do
    case %{refund_id: refund_id} |> RefundWorker.new() |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # A refund row never changes payment or Carried Fee, so a peek never goes
  # stale; refund commands lock payment → refund, and a Carried Fee's refund
  # (ALE-389) the person's entry → the fee → payment → refund, because its
  # failure gives the fee back (one live fee per person is guarded by the
  # entry lock). A fee's person only ever changes to none (hard delete).
  defp peek_refund(query) do
    case Repo.one(query) do
      nil -> {:error, :refund_not_found}
      refund -> {:ok, refund}
    end
  end

  defp refund_spec(%IntakeRefund{id: id, payment_id: payment_id, carried_fee_id: fee_id}) do
    %{
      waitlist_entry:
        fee_id &&
          from(e in WaitlistEntry,
            where:
              e.id in subquery(
                from(f in CarriedFee, where: f.id == ^fee_id, select: f.waitlist_id)
              )
          ),
      carried_fee: fee_id && required(from(f in CarriedFee, where: f.id == ^fee_id)),
      payment: payment_id && required(from(p in IntakePayment, where: p.id == ^payment_id)),
      refund: required(from(r in IntakeRefund, where: r.id == ^id))
    }
  end

  defp cast_refund_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :refund_not_found}
    end
  end

  # ── submit_refund ───────────────────────────────────────────────

  defp submit_refund(refund_id, clock) do
    with {:ok, id} <- cast_refund_id(refund_id),
         {:ok, peek} <- peek_refund(from(r in IntakeRefund, where: r.id == ^id)),
         {:ok, plan} <- transact(fn -> with_locked(refund_spec(peek), &submission_plan/1) end) do
      case plan do
        :settled -> {:ok, %{outcome: :already_submitted}}
        {:submit, refund, source} -> submit_to_stripe(refund, source, clock)
      end
    end
  end

  # Only a `pending` refund is submitted; one Stripe already answered for
  # (processing or terminal) is left to its events.
  defp submission_plan(%{refund: %IntakeRefund{status: "pending"} = refund, payment: payment}),
    do: {:ok, {:submit, refund, payment_intent_source(refund, payment)}}

  defp submission_plan(_locked), do: {:ok, :settled}

  defp payment_intent_source(%IntakeRefund{stripe_payment_intent_id: id}, _payment)
       when is_binary(id),
       do: {:payment_intent, id}

  defp payment_intent_source(_refund, %IntakePayment{stripe_payment_intent_id: id})
       when is_binary(id),
       do: {:payment_intent, id}

  defp payment_intent_source(_refund, %IntakePayment{stripe_checkout_session_id: id})
       when is_binary(id),
       do: {:checkout_session, id}

  defp payment_intent_source(_refund, _payment), do: :unresolvable

  # Between transactions. A Stripe outage keeps the refund `pending` and
  # fails, so the worker retries; a refusal makes it `failed`.
  defp submit_to_stripe(refund, source, clock) do
    with {:ok, payment_intent} <- resolve_payment_intent(source),
         {:ok, object} <- IntakeRefunds.create(refund, payment_intent) do
      record_refund(refund, object, %{stripe_payment_intent_id: payment_intent}, clock)
    else
      {:error, :retryable, reason} ->
        note_retryable(refund, reason)
        {:error, :stripe_unavailable}

      {:error, :rejected, reason} ->
        fail_refund(refund, reason, clock)
    end
  end

  defp resolve_payment_intent({:payment_intent, id}), do: {:ok, id}

  defp resolve_payment_intent({:checkout_session, session_id}) do
    case IntakeCheckout.retrieve(session_id) do
      {:ok, session} ->
        case IntakeCheckout.outcome(session) do
          {:complete, %{payment_intent: id}} when is_binary(id) -> {:ok, id}
          _other -> {:error, :rejected, :payment_intent_not_resolvable}
        end

      {:error, failure} ->
        {:error, failure, :checkout_session_unavailable}
    end
  end

  defp resolve_payment_intent(:unresolvable),
    do: {:error, :rejected, :payment_intent_not_resolvable}

  # Writes Stripe's answer (the create's response or an event's object)
  # after a locked re-read.
  defp record_refund(refund, object, extra, clock) do
    fn -> with_locked(refund_spec(refund), &record_refund_locked(&1, object, extra, clock)) end
    |> transact()
    |> signal_after_commit()
  end

  defp record_refund_locked(
         %{refund: refund} = locked,
         %{"id" => stripe_id} = object,
         extra,
         clock
       ) do
    cond do
      refund.status in ~w(completed failed) ->
        {:ok, {%{outcome: :already_settled}, []}}

      refund.stripe_refund_id not in [nil, stripe_id] ->
        {:ok, {%{outcome: :not_ours}, []}}

      true ->
        settle_refund(locked, object, extra, Clock.read(clock))
    end
  end

  defp settle_refund(%{refund: refund} = locked, %{"id" => stripe_id} = object, extra, reading) do
    provider_status = object["status"]
    status = IntakeRefunds.local_status(provider_status)

    changes =
      extra
      |> Map.merge(%{
        status: status,
        stripe_refund_id: stripe_id,
        provider_status: provider_status,
        processed_at: refund.processed_at || reading.now
      })
      |> Map.merge(settled_stamps(status, object, reading))

    changeset = Ecto.Changeset.change(refund, changes)

    write =
      if status == refund.status,
        do: persist(changeset),
        else: transition(:refund, refund, changeset)

    with {:ok, refund} <- write,
         {:ok, _fee} <- hold_fee_again(locked, refund, reading) do
      {:ok, {%{outcome: Map.fetch!(@refund_outcomes, status)}, notify_if_failed(refund)}}
    end
  end

  defp settled_stamps("completed", _object, reading), do: %{completed_at: reading.now}

  defp settled_stamps("failed", object, reading),
    do: %{failed_at: reading.now, last_error: object["failure_reason"] || "Stripe refund failed"}

  defp settled_stamps(_processing, _object, _reading), do: %{}

  defp fail_refund(refund, reason, clock) do
    fn -> with_locked(refund_spec(refund), &fail_refund_locked(&1, reason, clock)) end
    |> transact()
    |> signal_after_commit()
  end

  defp fail_refund_locked(
         %{refund: %IntakeRefund{status: "pending"} = refund} = locked,
         reason,
         clock
       ) do
    reading = Clock.read(clock)

    changeset =
      Ecto.Changeset.change(refund,
        status: "failed",
        failed_at: reading.now,
        last_error: error_text(reason)
      )

    with {:ok, refund} <- transition(:refund, refund, changeset),
         {:ok, _fee} <- hold_fee_again(locked, refund, reading),
         do: {:ok, {%{outcome: :failed}, notify_if_failed(refund)}}
  end

  defp fail_refund_locked(_settled, _reason, _clock),
    do: {:ok, {%{outcome: :already_settled}, []}}

  defp note_retryable(refund, reason) do
    _ =
      transact(fn ->
        with_locked(refund_spec(refund), fn
          %{refund: %IntakeRefund{status: "pending"} = refund} ->
            refund |> Ecto.Changeset.change(last_error: error_text(reason)) |> persist()

          %{refund: refund} ->
            {:ok, refund}
        end)
      end)

    :ok
  end

  defp error_text(reason), do: reason |> inspect() |> String.slice(0, 2_000)

  # ALE-389: a Carried Fee whose refund Stripe refused is held again, so the
  # person keeps their seat entitlement until a coordinator retries, records
  # a manual refund or forfeits it. A fee is `refunded` only by its one live
  # refund, so a `refunded` fee here is this refund's. If the person has
  # since come to hold another live fee (one per person), this one stays
  # `refunded` and the failed refund is still followed up.
  defp hold_fee_again(
         %{carried_fee: %CarriedFee{id: id, status: "refunded"} = fee},
         %IntakeRefund{status: "failed", carried_fee_id: id},
         reading
       ) do
    if other_live_fee?(fee),
      do: {:ok, fee},
      else:
        transition(:carried_fee, fee, CarriedFee.status_changeset(fee, "held", nil, reading.now))
  end

  defp hold_fee_again(_locked, _refund, _reading), do: {:ok, nil}

  defp other_live_fee?(%CarriedFee{waitlist_id: nil}), do: false

  defp other_live_fee?(%CarriedFee{id: id, waitlist_id: waitlist_id}),
    do: Repo.exists?(from(f in live_fee_query(waitlist_id), where: f.id != ^id))

  # A failed refund is a coordinator's job (story 84): a keyed Notification
  # per refund row, so a retried command never notifies twice.
  defp notify_if_failed(%IntakeRefund{status: "failed"} = refund) do
    %{first_name: first_name, date: date} = refund_person(refund)
    workshop = if date, do: " for the Beginners' Workshop on #{Values.date(date)}", else: ""

    follow_up =
      if refund.carried_fee_id,
        do:
          "It was a Carried Fee refund, so the fee is held again: retry it, record a manual " <>
            "refund or forfeit the fee from the workshop console or the Waitlist.",
        else: "Retry it or record a manual refund from the workshop console."

    alert(
      "beginners-workshop-refund:#{refund.id}:failed",
      "A refund of #{refund_amount(refund)} to #{first_name || "an anonymised person"}" <>
        "#{workshop} failed. " <> follow_up
    )
  end

  defp notify_if_failed(_refund), do: []

  # Who a refund pays back: the person of its Intake, or of its Carried Fee
  # when it has none (an imported fee's refund, ALE-389).
  defp refund_person(%IntakeRefund{intake_id: intake_id}) when is_binary(intake_id) do
    from(i in Intake,
      join: w in BeginnersWorkshop,
      on: w.id == i.workshop_id,
      left_join: p in UserProfile,
      on: p.waitlist_id == i.waitlist_id and not is_nil(i.waitlist_id),
      where: i.id == ^intake_id,
      limit: 1,
      select: %{first_name: p.first_name, date: w.date}
    )
    |> Repo.one!()
  end

  defp refund_person(%IntakeRefund{carried_fee_id: fee_id}) do
    from(f in CarriedFee,
      left_join: p in UserProfile,
      on: p.waitlist_id == f.waitlist_id and not is_nil(f.waitlist_id),
      where: f.id == ^fee_id,
      limit: 1,
      select: %{first_name: p.first_name, date: nil}
    )
    |> Repo.one!()
  end

  # ── apply_refund_event ──────────────────────────────────────────

  # Our refund by its Stripe id, or — when the event beat the submission's
  # record — by the refund id in its metadata. Anything else is a Workshop
  # refund (or no one's), which the Workshops target owns.
  defp apply_refund_event(%{"id" => stripe_id} = object, clock) when is_binary(stripe_id) do
    case peek_refund_for(object) do
      nil -> {:ok, %{outcome: :not_ours}}
      refund -> record_refund(refund, object, %{}, clock)
    end
  end

  defp apply_refund_event(_object, _clock), do: {:ok, %{outcome: :not_ours}}

  defp peek_refund_for(%{"id" => stripe_id} = object) do
    Repo.one(from(r in IntakeRefund, where: r.stripe_refund_id == ^stripe_id)) ||
      with id when is_binary(id) <- IntakeRefunds.refund_id(object),
           {:ok, id} <- Ecto.UUID.cast(id) do
        Repo.get(IntakeRefund, id)
      else
        _ -> nil
      end
  end

  # ── reconcile ───────────────────────────────────────────────────

  # One bounded pass repairing missed events: pending refunds are enqueued
  # again (the job is unique while incomplete), processing ones re-read from
  # Stripe, and live or releasing payment rows settled when their Checkout
  # Session completed or expired. Expired holds stay `reap_holds`'s job.
  defp reconcile(clock) do
    now = Clock.read(clock).now

    resubmitted =
      from(r in IntakeRefund,
        where: r.status == "pending",
        order_by: [asc: r.updated_at, asc: r.id],
        limit: @reconcile_batch,
        select: r.id
      )
      |> Repo.all()
      |> Enum.count(&(enqueue_refund(&1) == :ok))

    refunds =
      from(r in IntakeRefund,
        where: r.status == "processing" and not is_nil(r.stripe_refund_id),
        order_by: [asc: r.updated_at, asc: r.id],
        limit: @reconcile_batch
      )
      |> Repo.all()
      |> Enum.map(&reconcile_refund(&1, clock))

    payments =
      from(p in IntakePayment,
        where:
          not is_nil(p.stripe_checkout_session_id) and
            ((p.status == "open" and p.expires_at > ^now) or p.status == "releasing"),
        order_by: [asc: p.updated_at, asc: p.id],
        limit: @reconcile_batch,
        select: p.stripe_checkout_session_id
      )
      |> Repo.all()
      |> Enum.map(&reconcile_payment(&1, clock))

    {:ok,
     %{
       refunds_resubmitted: resubmitted,
       refunds_settled: Enum.count(refunds, &(&1 == :settled)),
       refunds_waiting: Enum.count(refunds, &(&1 == :waiting)),
       payments_settled: Enum.count(payments, &(&1 in [:released, :completed])),
       payments_waiting: Enum.count(payments, &(&1 == :waiting))
     }}
  end

  defp reconcile_refund(refund, clock) do
    with {:ok, object} <- IntakeRefunds.retrieve(refund.stripe_refund_id),
         {:ok, %{outcome: outcome}} when outcome in [:completed, :failed] <-
           record_refund(refund, object, %{}, clock) do
      :settled
    else
      _still_processing_or_unavailable -> :waiting
    end
  end

  defp reconcile_payment(session_id, clock) do
    case IntakeCheckout.retrieve(session_id) do
      {:ok, session} -> settle(session, clock)
      {:error, _unavailable} -> :waiting
    end
  end

  # ── retry_refund / record_manual_refund ─────────────────────────

  defp manual_note(attrs) do
    case fetch_attr(attrs, :note) do
      nil ->
        {:ok, nil}

      note when is_binary(note) ->
        {:ok, note |> String.trim() |> then(&if(&1 == "", do: nil, else: &1))}

      _other ->
        {:error, :invalid_payload}
    end
  end

  defp follow_up(scope, refund_id, principal_id, action, clock) do
    with {:ok, scoped} <- refund_scope(scope),
         {:ok, refund_id} <- cast_refund_id(refund_id),
         {:ok, peek} <- peek_refund(from(r in scoped, where: r.id == ^refund_id)) do
      transact(fn ->
        with_locked(refund_spec(peek), &follow_up_locked(&1, action, principal_id, clock))
      end)
    end
  end

  # A workshop console follows up its Intakes' refunds; the Waitlist tab
  # (ALE-389) the refunds of the person's Carried Fees.
  defp refund_scope({:person, waitlist_id}) do
    with {:ok, waitlist_id} <- cast_person_id(waitlist_id) do
      {:ok,
       from(r in IntakeRefund,
         join: f in CarriedFee,
         on: f.id == r.carried_fee_id,
         where: f.waitlist_id == ^waitlist_id
       )}
    end
  end

  defp refund_scope(workshop_id) do
    with {:ok, workshop_id} <- cast_id(workshop_id),
         do: {:ok, from(r in IntakeRefund, where: r.workshop_id == ^workshop_id)}
  end

  defp follow_up_locked(%{refund: failed} = locked, :forfeit, _principal_id, clock) do
    reading = Clock.read(clock)

    with :ok <- followable(failed),
         {:ok, fee} <- fee_to_follow_up(locked, :forfeit),
         {:ok, fee} <-
           transition(
             :carried_fee,
             fee,
             CarriedFee.status_changeset(fee, "forfeited", nil, reading.now)
           ) do
      {:ok, %{id: fee.id, status: fee.status, refund_id: failed.id}}
    end
  end

  defp follow_up_locked(%{refund: failed} = locked, action, principal_id, clock) do
    reading = Clock.read(clock)

    with :ok <- followable(failed),
         {:ok, fee} <- fee_to_follow_up(locked, action),
         {:ok, refund} <- follow_up_row(action, failed, locked.payment, principal_id, reading),
         {:ok, _fee} <- refund_fee_again(fee, reading) do
      {:ok, refund_view(refund)}
    end
  end

  # ALE-389: a Carried Fee's failed refund is followed up only while it is
  # the fee's latest and the fee is still owed back — held again (or, when
  # the person came to hold another fee, still `refunded`). Forfeit is only
  # for a Carried Fee's refund, and only while the fee is held.
  defp fee_to_follow_up(%{carried_fee: nil}, :forfeit), do: {:error, :not_a_carried_fee_refund}
  defp fee_to_follow_up(%{carried_fee: nil}, _action), do: {:ok, nil}

  defp fee_to_follow_up(%{carried_fee: fee, refund: failed}, action) do
    cond do
      superseded?(failed) -> {:error, :refund_followed_up}
      fee.status == "held" -> {:ok, fee}
      fee.status == "refunded" and action != :forfeit -> {:ok, fee}
      fee.status == "applied" -> {:error, :carried_fee_applied}
      true -> {:error, :carried_fee_not_held}
    end
  end

  # A later refund of the same Carried Fee (a new Refund Carried Fee or
  # Cancel with refund after this one failed) is the one to follow up.
  defp superseded?(%IntakeRefund{id: id, carried_fee_id: fee_id, created_at: at}) do
    Repo.exists?(
      from(r in IntakeRefund,
        where: r.carried_fee_id == ^fee_id and r.id != ^id and r.created_at > ^at
      )
    )
  end

  defp refund_fee_again(%CarriedFee{status: "held"} = fee, reading),
    do:
      transition(
        :carried_fee,
        fee,
        CarriedFee.status_changeset(fee, "refunded", nil, reading.now)
      )

  defp refund_fee_again(fee, _reading), do: {:ok, fee}

  # Every refund writer of a payment holds its lock; the follows index is
  # the backstop.
  defp followable(%IntakeRefund{status: "failed", id: id}) do
    if Repo.exists?(from(r in IntakeRefund, where: r.follows_refund_id == ^id)),
      do: {:error, :refund_followed_up},
      else: :ok
  end

  defp followable(_refund), do: {:error, :refund_not_failed}

  # A new key against the same payment; no email (story 144).
  defp follow_up_row(:retry, failed, payment, principal_id, reading) do
    with {:ok, refund} <-
           %{
             workshop_id: failed.workshop_id,
             intake_id: failed.intake_id,
             payment_id: failed.payment_id,
             carried_fee_id: failed.carried_fee_id,
             follows_refund_id: failed.id,
             reason: failed.reason,
             amount_cents: failed.amount_cents,
             currency: failed.currency,
             stripe_payment_intent_id:
               failed.stripe_payment_intent_id || (payment && payment.stripe_payment_intent_id),
             requested_by_principal_id: principal_id,
             requested_at: reading.now
           }
           |> IntakeRefund.request_changeset()
           |> persist(),
         :ok <- enqueue_refund(refund.id) do
      {:ok, refund}
    end
  end

  defp follow_up_row({:manual, note}, failed, _payment, principal_id, reading),
    do: failed |> IntakeRefund.manual_changeset(principal_id, note, reading.now) |> persist()

  defp refund_view(%IntakeRefund{} = refund) do
    Map.take(refund, [
      :id,
      :intake_id,
      :payment_id,
      :carried_fee_id,
      :follows_refund_id,
      :status,
      :method,
      :reason,
      :amount_cents,
      :currency,
      :requested_at,
      :completed_at,
      :failed_at
    ])
  end

  # ── Console Intake commands (ALE-386) ───────────────────────────

  # The shared plumbing of every console Intake command: an optional note,
  # one locked re-read, `IntakePolicy.check/2` deciding, the command's own
  # act, and one history row when it acted. A repeat that finds the Intake
  # already where the command leads succeeds and writes nothing.
  defp intake_command(command, principal_id, workshop_id, intake_id, attrs, clock) do
    with {:ok, context} <- intake_command_context(command, principal_id, attrs),
         {:ok, workshop_id} <- cast_id(workshop_id),
         {:ok, peek} <- peek_console_intake(workshop_id, intake_id) do
      transact(fn ->
        with_locked(
          intake_command_spec(command, peek),
          &intake_command_locked(&1, command, context, clock)
        )
      end)
    end
  end

  # Who runs the command, their optional note, and the command's own
  # options, all checked before any lock.
  defp intake_command_context(command, principal_id, attrs) do
    with {:ok, note} <- command_note(attrs),
         {:ok, options} <- command_options(command, attrs) do
      {:ok, %{actor: principal_id, note: note, options: options}}
    end
  end

  # `withdraw` (ALE-387) takes the refund-or-forfeit choice: absent, or a
  # boolean. Whether it is *required* depends on the locked Intake.
  # `delete_person` (ALE-396) takes the same choice for a Carried Fee.
  defp command_options(command, attrs) when command in [:withdraw, :delete_person] do
    case fetch_attr(attrs, :refund) do
      refund when is_nil(refund) or is_boolean(refund) -> {:ok, %{refund: refund}}
      _other -> {:error, :invalid_refund_choice}
    end
  end

  # `correct_attendance` (ALE-393) names the state the Intake becomes.
  defp command_options(:correct_attendance, attrs) do
    case fetch_attr(attrs, :to) do
      to when is_binary(to) ->
        if to in IntakePolicy.correction_states(),
          do: {:ok, %{to: to}},
          else: {:error, :invalid_correction}

      _other ->
        {:error, :invalid_correction}
    end
  end

  defp command_options(_command, _attrs), do: {:ok, %{}}

  defp command_note(attrs) do
    case fetch_attr(attrs, :note) do
      nil ->
        {:ok, nil}

      note when is_binary(note) ->
        note |> String.trim() |> bounded_note()

      _other ->
        {:error, :invalid_note}
    end
  end

  defp bounded_note(""), do: {:ok, nil}

  defp bounded_note(note) do
    if String.length(note) <= IntakeEvent.note_max(),
      do: {:ok, note},
      else: {:error, :invalid_note}
  end

  # Unlocked: which person the Intake is (to lock their Waitlist entry
  # before the Intake). An Intake never changes workshop or person; only
  # anonymisation nulls the person, which the locked re-read sees.
  defp peek_console_intake(workshop_id, intake_id) do
    with {:ok, intake_id} <- Ecto.UUID.cast(intake_id),
         %{} = peek <-
           Repo.one(
             from(i in Intake,
               where: i.id == ^intake_id and i.workshop_id == ^workshop_id,
               select: %{intake_id: i.id, workshop_id: i.workshop_id, waitlist_id: i.waitlist_id}
             )
           ) do
      {:ok, peek}
    else
      _ -> {:error, :intake_not_found}
    end
  end

  # `decline` changes the person's standing and may release their hold, so
  # it locks the Waitlist entry and the live Seat Hold too.
  defp intake_command_spec(:decline, %{waitlist_id: waitlist_id} = peek) do
    peek
    |> intake_spec(open_payment(peek.intake_id))
    |> Map.put(
      :waitlist_entry,
      waitlist_id && from(e in WaitlistEntry, where: e.id == ^waitlist_id)
    )
  end

  # `defer` returns the person to `waiting` and carries their fee: it locks
  # their entry, their Carried Fee and the payment that paid a Stripe-paid
  # Intake (the fee points at it); `confirm` applies the fee.
  defp intake_command_spec(:defer, peek) do
    peek
    |> intake_spec(paying_payment(peek.intake_id))
    |> Map.put(:waitlist_entry, entry_query(peek))
    |> Map.put(:carried_fee, &locked_intake_fee/1)
  end

  defp intake_command_spec(:confirm, peek),
    do: peek |> intake_spec(nil) |> Map.put(:carried_fee, &locked_intake_fee/1)

  # `cancel_with_refund` refunds the money that paid the Intake and puts
  # the person back to `waiting`, so it locks their entry, their Carried Fee
  # (ALE-389: the one that paid a Carried-Fee-paid Intake) and the payment
  # that paid a Stripe-paid one. A Carried Fee's original payment row is
  # never edited, so its refund reads it without a lock; the fee lock
  # serialises every refund of the fee.
  defp intake_command_spec(:cancel_with_refund, peek) do
    peek
    |> intake_spec(paying_payment(peek.intake_id))
    |> Map.put(:waitlist_entry, entry_query(peek))
    |> Map.put(:carried_fee, &locked_intake_fee/1)
  end

  # `withdraw` removes the person and settles their money; which payment it
  # locks depends on the locked Intake: a contacted one's live hold, a paid
  # one's payment; and (ALE-389) the person's Carried Fee.
  defp intake_command_spec(:withdraw, peek) do
    peek
    |> intake_spec(fn
      %{intake: %Intake{state: "contacted"}} -> open_payment(peek.intake_id)
      %{intake: %Intake{state: "paid"}} -> paying_payment(peek.intake_id)
      _closed -> nil
    end)
    |> Map.put(:waitlist_entry, entry_query(peek))
    |> Map.put(:carried_fee, &locked_intake_fee/1)
  end

  # ALE-389: refunding the person's Carried Fee locks their entry and the fee.
  defp intake_command_spec(:refund_carried_fee, peek) do
    peek
    |> intake_spec(nil)
    |> Map.put(:waitlist_entry, entry_query(peek))
    |> Map.put(:carried_fee, &locked_intake_fee/1)
  end

  # `correct_attendance` (ALE-393) moves the standing and the Carried Fee
  # that paid the Intake (or, for a Stripe payer's deferral, makes one on the
  # paying payment, so it locks the person's live fee and that payment).
  defp intake_command_spec(:correct_attendance, peek) do
    peek
    |> intake_spec(fn
      %{intake: %Intake{paid_via: "stripe"}} -> paying_payment(peek.intake_id)
      _carried_fee_paid -> nil
    end)
    |> Map.put(:waitlist_entry, entry_query(peek))
    |> Map.put(:carried_fee, &correction_fee/1)
  end

  defp intake_command_spec(_link_command, peek), do: intake_spec(peek, nil)

  defp entry_query(%{waitlist_id: nil}), do: nil
  defp entry_query(%{waitlist_id: id}), do: from(e in WaitlistEntry, where: e.id == ^id)

  # The payment that paid an Intake: its `paid` row that was not refunded
  # automatically (a completion after the Intake had closed, or one that
  # failed the amount check, is refunded on its own and never paid it).
  defp paying_payment(intake_id) do
    automatic = IntakeRefund.automatic_reasons()

    from(p in IntakePayment,
      as: :payment,
      where: p.intake_id == ^intake_id and p.status == "paid",
      where:
        not exists(
          from(r in IntakeRefund,
            where: r.payment_id == parent_as(:payment).id and r.reason in ^automatic
          )
        ),
      order_by: [asc: p.paid_at, asc: p.id],
      limit: 1
    )
  end

  defp intake_command_locked(%{intake: intake} = locked, command, context, clock) do
    reading = Clock.read(clock)

    case IntakePolicy.check(command, policy_facts(locked, context)) do
      :ok ->
        event_id = Ecto.UUID.generate()

        with {:ok, intake} <-
               act_on_intake(command, Map.put(locked, :context, context), event_id, reading),
             {:ok, _event} <- record_intake_event(intake, command, event_id, context, reading) do
          {:ok, intake_command_view(intake, :done)}
        end

      :already_done ->
        {:ok, intake_command_view(intake, :already_done)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp act_on_intake(:decline, locked, _event_id, reading) do
    %{workshop: workshop, waitlist_entry: entry, intake: intake, payment: hold} = locked

    with {:ok, intake} <-
           transition(:intake, intake, Intake.close_changeset(intake, "declined")),
         :ok <- release_to_stripe(hold),
         :ok <- back_to_waiting(entry),
         :ok <-
           queue_intake_email(
             intake,
             "declined",
             "declined",
             &%{"firstName" => &1, "date" => Values.date(workshop.date)},
             reading
           ) do
      {:ok, intake}
    end
  end

  # A deferral keeps the person's money as a Carried Fee and their place in
  # the queue (story 69): a Stripe-paid Intake creates a `held` fee pointing
  # at its payment, a Carried-Fee-paid one returns its fee to `held`.
  defp act_on_intake(:defer, %{workshop: workshop} = locked, _event_id, reading) do
    with {:ok, intake} <- defer_paid(locked, reading),
         :ok <-
           queue_intake_email(
             intake,
             "deferred",
             "deferred",
             &%{"firstName" => &1, "date" => Values.date(workshop.date)},
             reading
           ) do
      {:ok, intake}
    end
  end

  # ALE-387: a paid person wants their money back. The seat is free at once
  # (it counted only while `paid`); the person keeps their priority. A
  # Stripe-paid Intake refunds its payment; (ALE-389) a Carried-Fee-paid one
  # refunds the Carried Fee, against the fee's original payment.
  defp act_on_intake(:cancel_with_refund, locked, _event_id, reading) do
    %{workshop: workshop, waitlist_entry: entry, intake: intake, context: context} = locked

    with {:ok, intake} <-
           transition(:intake, intake, Intake.close_changeset(intake, "cancelled_refunded")),
         {:ok, refund} <- refund_paid(intake, locked, "cancelled_with_refund", context, reading),
         :ok <- back_to_waiting(entry),
         :ok <-
           queue_intake_email(
             intake,
             "cancelled_with_refund",
             "cancelled_with_refund",
             &%{
               "firstName" => &1,
               "date" => Values.date(workshop.date),
               "refundAmount" => refund_amount(refund)
             },
             reading
           ) do
      {:ok, intake}
    end
  end

  # Takes a seat under the workshop lock with the same rule as a Seat Hold,
  # but needs no hold: nothing outside this transaction is called. The
  # Payment Cutoff does not stop it (only new Stripe holds); finalisation
  # closes the Intake, which ends it.
  defp act_on_intake(:confirm, locked, _event_id, reading) do
    %{workshop: workshop, intake: intake, carried_fee: fee} = locked

    cond do
      workshop.status != "scheduled" ->
        {:error, :intake_closed}

      not WorkshopPolicy.seat_free?(workshop, facts_for(workshop)) ->
        {:error, :full}

      true ->
        with {:ok, intake} <-
               transition(
                 :intake,
                 intake,
                 Intake.paid_changeset(intake, {"carried_fee", fee.id}, reading.now)
               ),
             {:ok, _fee} <-
               transition(
                 :carried_fee,
                 fee,
                 CarriedFee.status_changeset(fee, "applied", intake.id, reading.now)
               ),
             :ok <- queue_place_confirmed(intake, workshop, "place_confirmed", reading),
             :ok <- pre_workshop_if_cutoff_passed(intake, workshop, reading) do
          {:ok, intake}
        end
    end
  end

  # ALE-387: the person leaves the Waitlist. A contacted Intake closes as
  # `declined` (its live hold stops counting); a paid one closes as
  # `withdrawn` — freeing the seat at once. Money is never handled
  # implicitly: a paid Intake, and (ALE-389) any Carried Fee the person
  # holds, needs the refund-or-forfeit choice, and the person is told which.
  # A contacted Intake of someone without a Carried Fee emails nobody.
  defp act_on_intake(:withdraw, %{intake: %Intake{state: "contacted"}} = locked, _id, reading) do
    %{waitlist_entry: entry, intake: intake, payment: hold, carried_fee: fee} = locked

    with {:ok, refund?} <- money_choice(fee, locked.context.options),
         {:ok, intake} <-
           transition(:intake, intake, Intake.close_changeset(intake, "declined")),
         :ok <- release_to_stripe(hold),
         :ok <- remove_from_waitlist(entry),
         :ok <- settle_withdrawn(refund?, locked, intake, reading),
         do: {:ok, intake}
  end

  defp act_on_intake(:withdraw, %{intake: %Intake{state: "paid"}} = locked, _id, reading) do
    %{waitlist_entry: entry, intake: intake, context: context} = locked

    with {:ok, refund?} <- refund_choice(context.options),
         {:ok, intake} <- transition(:intake, intake, Intake.close_changeset(intake, "withdrawn")),
         :ok <- remove_from_waitlist(entry),
         :ok <- settle_withdrawn(refund?, locked, intake, reading) do
      {:ok, intake}
    end
  end

  # ALE-389: the person's `held` Carried Fee is refunded (the full amount
  # originally paid, against the original payment). Nothing else moves: the
  # Intake stays where it is — a contacted one now asks for payment, since
  # its person holds no fee — and the standing and priority are untouched.
  # "Carried Fee refunded" is queued.
  defp act_on_intake(:refund_carried_fee, locked, _event_id, reading) do
    %{waitlist_entry: entry, intake: intake, carried_fee: fee, context: context} = locked

    with {:ok, refund} <- refund_held_fee(entry, fee, intake, context.actor, reading),
         :ok <-
           queue_intake_email(
             intake,
             "carried_fee_refunded",
             "carried_fee_refunded:#{refund.id}",
             &%{"firstName" => &1, "refundAmount" => refund_amount(refund)},
             reading
           ) do
      {:ok, intake}
    end
  end

  defp act_on_intake(:resend_link, %{workshop: workshop, intake: intake}, event_id, reading) do
    with :ok <- queue_link_email(intake, workshop, "resend_link:#{event_id}", reading),
         do: {:ok, intake}
  end

  defp act_on_intake(:rotate_link, %{workshop: workshop, intake: intake}, event_id, reading) do
    token = IntakeLink.token(intake.id, intake.link_generation + 1)

    with {:ok, intake} <-
           intake |> Intake.rotate_link_changeset(IntakeLink.hash(token)) |> persist(),
         :ok <- queue_link_email(intake, workshop, "rotate_link:#{event_id}", reading) do
      {:ok, intake}
    end
  end

  # ALE-393: fix a door mistake, or turn a no-show into a Deferral. The
  # standing and the Carried Fee follow the new state; only a deferral is
  # emailed, and an attendee owed the Follow-up gets it now.
  defp act_on_intake(:correct_attendance, locked, _event_id, reading) do
    %{workshop: workshop, waitlist_entry: entry, intake: intake, context: context} = locked
    to = context.options.to

    with :ok <- no_other_open_intake(entry, intake, to),
         {:ok, intake} <- transition(:intake, intake, Intake.close_changeset(intake, to)),
         :ok <- correct_standing(entry, to),
         {:ok, _fee} <- correct_fee(intake, locked, to, reading),
         :ok <- after_correction(intake, workshop, to, reading) do
      {:ok, intake}
    else
      # The person's record moved on since finalisation (a refunded fee,
      # another live fee, a standing the table cannot reach from here): the
      # correction no longer fits, so it is refused by name.
      {:error, reason} when reason in [:illegal_transition, :illegal_standing_change] ->
        {:error, :not_correctable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The deferral itself, shared by `defer` and `cancel_workshop` (which
  # sends its own notice instead of "Deferred"): the fee is carried, the
  # Intake closes as `deferred` and the person is `waiting` again with
  # their original priority. `locked` holds this Intake's person's entry,
  # live Carried Fee and paying payment.
  defp defer_paid(%{waitlist_entry: entry, intake: intake} = locked, reading) do
    with {:ok, _fee} <- carry_fee(intake, locked, reading),
         {:ok, intake} <-
           transition(:intake, intake, Intake.close_changeset(intake, "deferred")),
         :ok <- back_to_waiting(entry),
         do: {:ok, intake}
  end

  defp refund_choice(%{refund: refund}) when is_boolean(refund), do: {:ok, refund}
  defp refund_choice(_options), do: {:error, :refund_choice_required}

  # The refund-or-forfeit choice, required only when there is money to
  # handle: a Carried Fee (ALE-389). `nil` means nothing to settle.
  defp money_choice(nil, _options), do: {:ok, nil}
  defp money_choice(%CarriedFee{}, options), do: refund_choice(options)

  # What a withdrawal does with the person's money, and the notice saying
  # so: the payment that paid a Stripe-paid Intake and the person's Carried
  # Fee (the one that paid a Carried-Fee-paid Intake, or a held one) are
  # refunded or forfeited together. `nil`: there was no money.
  defp settle_withdrawn(nil, _locked, _intake, _reading), do: :ok

  defp settle_withdrawn(true, %{context: context} = locked, intake, reading) do
    with {:ok, payment_refund} <- refund_withdrawn_payment(intake, locked, context, reading),
         {:ok, fee_refund} <-
           refund_fee(locked.carried_fee, intake, context.actor, "withdrawn", reading) do
      refund = payment_refund || fee_refund

      queue_intake_email(
        intake,
        "withdrawn_refunded",
        "withdrawn",
        &%{"firstName" => &1, "refundAmount" => refund_amount(refund)},
        reading
      )
    end
  end

  defp settle_withdrawn(false, locked, intake, reading) do
    with {:ok, _fee} <- forfeit_fee(locked.carried_fee, reading) do
      queue_intake_email(
        intake,
        "withdrawn_forfeited",
        "withdrawn",
        &%{"firstName" => &1},
        reading
      )
    end
  end

  # Only a Stripe-paid `withdrawn` Intake has a payment of its own to refund.
  defp refund_withdrawn_payment(%Intake{state: "withdrawn", paid_via: "stripe"}, l, c, reading),
    do: request_staff_refund(l, "withdrawn", c, reading)

  defp refund_withdrawn_payment(_intake, _locked, _context, _reading), do: {:ok, nil}

  # The money that paid a paid Intake: its Stripe payment, or the Carried
  # Fee it was confirmed with.
  defp refund_paid(%Intake{paid_via: "carried_fee"} = intake, locked, reason, context, reading) do
    case locked.carried_fee do
      %CarriedFee{id: id} = fee when id == intake.carried_fee_id ->
        refund_fee(fee, intake, context.actor, reason, reading)

      _moved_on ->
        {:error, :illegal_transition}
    end
  end

  defp refund_paid(_stripe_paid, locked, reason, context, reading),
    do: request_staff_refund(locked, reason, context, reading)

  # A withdrawn person's standing becomes `removed` (which starts the
  # retention clock); one already removed stays so. An Invitation already
  # under way belongs to Onboarding, so withdraw refuses it. An anonymised
  # person has no standing.
  defp remove_from_waitlist(nil), do: :ok
  defp remove_from_waitlist(%WaitlistEntry{status: "removed"}), do: :ok

  defp remove_from_waitlist(%WaitlistEntry{status: status}) when status in ~w(invited joined),
    do: {:error, :already_invited}

  defp remove_from_waitlist(%WaitlistEntry{id: id}) do
    with {:ok, _entry} <- Waitlist.change_standing(id, "removed"), do: :ok
  end

  # A live Seat Hold of a closing Intake stops counting as a seat at once;
  # only Stripe ends the session (`release_payment`, `reconcile`), and a
  # completion that arrives anyway is refunded (`refund_after_close/2`).
  defp release_to_stripe(nil), do: :ok

  defp release_to_stripe(%IntakePayment{} = hold) do
    with {:ok, _hold} <-
           transition(:payment, hold, Ecto.Changeset.change(hold, status: "releasing")),
         do: :ok
  end

  # A contacted person is `waiting`, so their original priority stands; one
  # staff removed while contacted goes back to `waiting` (the Waitlist
  # keeps their registration date). An anonymised person has no standing.
  defp back_to_waiting(%WaitlistEntry{status: "removed", id: id}) do
    with {:ok, _entry} <- Waitlist.change_standing(id, "waiting"), do: :ok
  end

  defp back_to_waiting(_waiting_or_anonymised), do: :ok

  # The email an open Intake's link travels in: "Contact – pay" while
  # contacted (its window is its Batch's, or the Payment Cutoff for a
  # fast-track), "Place confirmed" once paid.
  defp queue_link_email(%Intake{waitlist_id: nil}, _workshop, _occasion, _reading), do: :ok

  defp queue_link_email(%Intake{state: "contacted"} = intake, workshop, occasion, reading) do
    case Repo.get(WaitlistEntry, intake.waitlist_id) do
      %WaitlistEntry{email: email} = entry when is_binary(email) ->
        queue_contact_email(
          intake,
          entry,
          first_name_of(intake.waitlist_id),
          workshop,
          intake_window_end(intake, workshop),
          occasion,
          reading
        )

      _anonymised ->
        :ok
    end
  end

  defp queue_link_email(%Intake{state: "paid"} = intake, workshop, occasion, reading),
    do: queue_place_confirmed(intake, workshop, occasion, reading)

  defp intake_window_end(%Intake{batch_id: nil}, workshop), do: workshop.payment_cutoff

  defp intake_window_end(%Intake{batch_id: batch_id}, _workshop),
    do: Repo.one!(from(b in Batch, where: b.id == ^batch_id, select: b.window_ends_at))

  # What `IntakePolicy.check/2` reads: the locked Intake and, for the
  # commands that lock them, the person's live Carried Fee and standing,
  # the workshop's status, and a correction's target (ALE-393).
  defp policy_facts(%{intake: intake} = locked, context) do
    %{
      state: intake.state,
      paid_via: intake.paid_via,
      carried_fee:
        case Map.get(locked, :carried_fee) do
          %CarriedFee{status: status} -> status
          nil -> nil
        end,
      workshop_status: locked.workshop.status,
      standing:
        case Map.get(locked, :waitlist_entry) do
          %WaitlistEntry{status: status} ->
            status

          # ALE-396: an anonymised attendee keeps what became of them.
          _anonymised when intake.invitation_outcome in ~w(invited joined) ->
            intake.invitation_outcome

          _none ->
            nil
        end,
      correction: Map.get(context.options, :to)
    }
  end

  defp record_intake_event(intake, command, event_id, context, reading) do
    %{actor: actor, note: note, options: options} = context

    %{
      id: event_id,
      intake_id: intake.id,
      command: Atom.to_string(command),
      actor_principal_id: actor,
      note: note,
      correction: Map.get(options, :to),
      occurred_at: reading.now
    }
    |> IntakeEvent.changeset()
    |> persist()
  end

  defp intake_command_view(%Intake{} = intake, outcome) do
    intake
    |> Map.take([:id, :workshop_id, :state, :link_generation])
    |> Map.put(:outcome, outcome)
  end

  # ── correct_attendance (ALE-393) ────────────────────────────────

  @correction_standings %{
    "attended" => "attended",
    "no_show" => "removed",
    "deferred" => "waiting"
  }

  # The Carried Fee that paid the Intake; a Stripe payer's live one (which a
  # deferral would have to be the only one of).
  defp correction_fee(%{intake: %Intake{carried_fee_id: id}}) when is_binary(id),
    do: from(f in CarriedFee, where: f.id == ^id)

  defp correction_fee(locked), do: locked_intake_fee(locked)

  # An attendee is no longer on the Waitlist, so someone who has since been
  # placed in another workshop cannot become one here. Every Intake is
  # created under the person's entry lock, which this command holds.
  defp no_other_open_intake(%WaitlistEntry{id: waitlist_id}, %Intake{id: intake_id}, "attended") do
    if Repo.exists?(
         from(i in Intake,
           where:
             i.waitlist_id == ^waitlist_id and i.id != ^intake_id and
               i.state in ^Intake.open_states()
         )
       ),
       do: {:error, :open_intake},
       else: :ok
  end

  defp no_other_open_intake(_entry, _intake, _to), do: :ok

  # The standing follows the lifecycle; one already there is left alone. An
  # anonymised person has no standing.
  defp correct_standing(nil, _to), do: :ok

  defp correct_standing(%WaitlistEntry{status: status, id: id}, to) do
    case Map.fetch!(@correction_standings, to) do
      ^status -> :ok
      standing -> with {:ok, _entry} <- Waitlist.change_standing(id, standing), do: :ok
    end
  end

  # A Carried Fee that paid the Intake is spent on attendance, forfeited on
  # a no-show and held again on a deferral; a Stripe payer's deferral makes
  # a held fee on the paying payment, as `defer` does.
  defp correct_fee(
         %Intake{paid_via: "carried_fee", carried_fee_id: id} = intake,
         %{carried_fee: %CarriedFee{id: id} = fee},
         to,
         reading
       ) do
    {status, applied_intake_id} =
      case to do
        "attended" -> {"spent", intake.id}
        "no_show" -> {"forfeited", intake.id}
        "deferred" -> {"held", nil}
      end

    transition(
      :carried_fee,
      fee,
      CarriedFee.status_changeset(fee, status, applied_intake_id, reading.now)
    )
  end

  defp correct_fee(%Intake{paid_via: "carried_fee"}, _locked, _to, _reading),
    do: {:error, :illegal_transition}

  defp correct_fee(%Intake{} = intake, locked, "deferred", reading),
    do: carry_fee(intake, locked, reading)

  defp correct_fee(_stripe_paid, _locked, _to, _reading), do: {:ok, nil}

  defp after_correction(intake, workshop, "attended", reading) do
    if WorkshopPolicy.follow_up_due?(workshop, reading) do
      with {:ok, _queued_or_not_owed} <- queue_follow_up(intake, workshop, reading), do: :ok
    else
      :ok
    end
  end

  defp after_correction(intake, workshop, "deferred", reading),
    do:
      queue_intake_email(
        intake,
        "deferred",
        "deferred",
        &%{"firstName" => &1, "date" => Values.date(workshop.date)},
        reading
      )

  defp after_correction(_intake, _workshop, "no_show", _reading), do: :ok

  # ── withdraw from the Waitlist tab (ALE-387) ───────────────────

  # The Waitlist tab names the person. With an open Intake this is exactly
  # the console's `withdraw` on it (same lock order, rule and history row);
  # without one only the standing changes. The open Intake is peeked
  # unlocked, so a Batch or Fast-track that contacts the person meanwhile
  # is caught under the lock and the attempt retries from a fresh peek.
  defp withdraw_person(principal_id, waitlist_id, attrs, clock) do
    with {:ok, context} <- intake_command_context(:withdraw, principal_id, attrs),
         {:ok, waitlist_id} <- cast_person_id(waitlist_id) do
      withdraw_person_attempt(waitlist_id, context, clock, @batch_attempts)
    end
  end

  defp withdraw_person_attempt(waitlist_id, context, clock, attempts) do
    case transact(fn -> withdraw_person_locked(waitlist_id, context, clock) end) do
      {:error, :concurrent_change} when attempts > 1 ->
        withdraw_person_attempt(waitlist_id, context, clock, attempts - 1)

      result ->
        result
    end
  end

  defp withdraw_person_locked(waitlist_id, context, clock) do
    case peek_open_intake(waitlist_id) do
      nil ->
        with_locked(
          %{
            waitlist_entry: from(e in WaitlistEntry, where: e.id == ^waitlist_id),
            carried_fee: live_fee_query(waitlist_id)
          },
          &withdraw_standing(&1, waitlist_id, context, clock)
        )

      peek ->
        with_locked(
          intake_command_spec(:withdraw, peek),
          &withdraw_open_intake(&1, waitlist_id, context, clock)
        )
    end
  end

  defp peek_open_intake(waitlist_id) do
    Repo.one(
      from(i in Intake,
        where: i.waitlist_id == ^waitlist_id and i.state in ^Intake.open_states(),
        select: %{intake_id: i.id, workshop_id: i.workshop_id, waitlist_id: i.waitlist_id}
      )
    )
  end

  defp open_intake_of?(%{waitlist_entry: %WaitlistEntry{}, intake: %Intake{} = intake}, id),
    do: intake.waitlist_id == id and intake.state in Intake.open_states()

  defp open_intake_of?(_locked, _id), do: false

  # The peeked Intake must still be this person's open one under the lock.
  defp withdraw_open_intake(locked, waitlist_id, context, clock) do
    with true <- open_intake_of?(locked, waitlist_id) || {:error, :concurrent_change},
         {:ok, view} <- intake_command_locked(locked, :withdraw, context, clock) do
      {:ok, withdraw_person_view(Repo.reload!(locked.waitlist_entry), view)}
    end
  end

  # No open Intake: the standing, under the entry lock, and (ALE-389) the
  # person's Carried Fee, which needs the refund-or-forfeit choice even
  # when they are already removed. An Intake created since the peek (it
  # takes this lock too) is found here.
  defp withdraw_standing(%{waitlist_entry: nil}, _waitlist_id, _context, _clock),
    do: {:error, :person_not_found}

  defp withdraw_standing(%{waitlist_entry: entry, carried_fee: fee}, waitlist_id, context, clock) do
    cond do
      peek_open_intake(waitlist_id) != nil ->
        {:error, :concurrent_change}

      entry.status == "removed" and fee == nil ->
        {:ok, withdraw_person_view(entry, nil, :already_done)}

      true ->
        with {:ok, refund?} <- money_choice(fee, context.options),
             :ok <- remove_from_waitlist(entry),
             :ok <- settle_withdrawn_fee(refund?, entry, fee, context, Clock.read(clock)),
             do: {:ok, withdraw_person_view(Repo.reload!(entry), nil, :done)}
    end
  end

  # A withdrawal with no Intake settles the Carried Fee alone; its notice is
  # logged on the fee's original Intake, if any.
  defp settle_withdrawn_fee(nil, _entry, _fee, _context, _reading), do: :ok

  defp settle_withdrawn_fee(true, entry, fee, context, reading) do
    with {:ok, refund} <- refund_fee(fee, nil, context.actor, "withdrawn", reading) do
      queue_person_notice(
        entry,
        refund.intake_id,
        "withdrawn_refunded",
        "withdrawn:#{refund.id}",
        %{"firstName" => first_name_of(entry.id), "refundAmount" => refund_amount(refund)},
        reading
      )
    end
  end

  defp settle_withdrawn_fee(false, entry, fee, _context, reading) do
    with {:ok, fee} <- forfeit_fee(fee, reading) do
      queue_person_notice(
        entry,
        nil,
        "withdrawn_forfeited",
        "withdrawn:#{fee.id}",
        %{"firstName" => first_name_of(entry.id)},
        reading
      )
    end
  end

  defp withdraw_person_view(entry, intake_view),
    do: withdraw_person_view(entry, intake_view, intake_view.outcome)

  defp withdraw_person_view(%WaitlistEntry{} = entry, intake_view, outcome),
    do: %{waitlist_id: entry.id, status: entry.status, intake: intake_view, outcome: outcome}

  defp cast_person_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :person_not_found}
    end
  end

  # ── Hard delete: delete_person and purge_retention (ALE-396) ───

  # The person's rows a hard delete changes: their entry, every Intake they
  # ever had (anonymised), and their live Carried Fee (refunded or
  # forfeited first). Every Intake is created under the person's entry lock,
  # so no new one can appear while it is held.
  defp person_delete_spec(waitlist_id) do
    %{
      waitlist_entry: from(e in WaitlistEntry, where: e.id == ^waitlist_id),
      intake: {:all, from(i in Intake, where: i.waitlist_id == ^waitlist_id)},
      carried_fee: live_fee_query(waitlist_id)
    }
  end

  # The coordinator's delete, at any time on request: refused with an open
  # Intake or once the Invitation handoff is under way; a Carried Fee needs
  # the refund-or-forfeit choice first. Deletion emails nobody.
  defp delete_person(principal_id, waitlist_id, attrs, clock) do
    with {:ok, %{refund: refund}} <- command_options(:delete_person, attrs),
         {:ok, waitlist_id} <- cast_person_id(waitlist_id) do
      transact(fn ->
        with_locked(
          person_delete_spec(waitlist_id),
          &delete_person_locked(&1, principal_id, refund, clock)
        )
      end)
    end
  end

  defp delete_person_locked(%{waitlist_entry: nil}, _principal_id, _refund, _clock),
    do: {:error, :person_not_found}

  defp delete_person_locked(locked, principal_id, refund, clock) do
    %{waitlist_entry: entry, intake: intakes, carried_fee: fee} = locked
    reading = Clock.read(clock)

    with :ok <- none_open(intakes),
         :ok <- deletable_standing(entry),
         {:ok, refund?} <- money_choice(fee, %{refund: refund}),
         {:ok, fee} <- settle_deleted_fee(refund?, fee, principal_id, reading),
         {:ok, anonymised} <- hard_delete(entry, intakes, reading) do
      {:ok, deleted_view(entry, anonymised, fee, :deleted)}
    end
  end

  defp none_open(intakes) do
    if Enum.any?(intakes, &(&1.state in Intake.open_states())),
      do: {:error, :open_intake},
      else: :ok
  end

  # An Invitation already under way, or a Member, belongs to Onboarding.
  defp deletable_standing(%WaitlistEntry{status: status}) when status in ~w(invited joined),
    do: {:error, :not_deletable}

  defp deletable_standing(%WaitlistEntry{}), do: :ok

  # The Carried Fee, settled by the coordinator's choice: refunded in full
  # against its original payment (the refund row outlives the person) or
  # forfeited. `nil`: there was no money.
  defp settle_deleted_fee(nil, _fee, _actor, _reading), do: {:ok, nil}

  defp settle_deleted_fee(true, fee, actor, reading) do
    with {:ok, _refund} <- refund_fee(fee, nil, actor, "deleted", reading),
         do: {:ok, Repo.reload!(fee)}
  end

  defp settle_deleted_fee(false, fee, _actor, reading), do: forfeit_fee(fee, reading)

  # The time-driven purge (`:system`, a sweep pass): someone `removed` for
  # more than the 3-month retention window — judged with the boundary
  # clock under the entry lock — is hard-deleted and any `held` Carried Fee
  # forfeited. A removed person whose Intake is still open (staff removed
  # them while contacted) waits until it closes.
  defp purge_retention(waitlist_id, clock) do
    with {:ok, waitlist_id} <- cast_person_id(waitlist_id) do
      transact(fn -> with_locked(person_delete_spec(waitlist_id), &purge_locked(&1, clock)) end)
    end
  end

  defp purge_locked(%{waitlist_entry: nil}, _clock), do: {:ok, %{outcome: :not_due}}

  defp purge_locked(%{waitlist_entry: entry, intake: intakes, carried_fee: fee}, clock) do
    reading = Clock.read(clock)

    if retention_ended?(entry, reading) and none_open(intakes) == :ok do
      with {:ok, fee} <- forfeit_fee(fee, reading),
           {:ok, anonymised} <- hard_delete(entry, intakes, reading),
           do: {:ok, deleted_view(entry, anonymised, fee, :purged)}
    else
      {:ok, %{waitlist_id: entry.id, outcome: :not_due}}
    end
  end

  defp retention_ended?(%WaitlistEntry{status: "removed", removed_at: %DateTime{} = at}, reading),
    do: not Waitlist.restorable?(at, reading.now)

  defp retention_ended?(%WaitlistEntry{}, _reading), do: false

  # The one hard delete: the person's Intakes are anonymised (each keeps its
  # queue date; an attended one first records whether the person had been
  # invited or had joined), every Carried Fee row of theirs is kept with no
  # link to them, and the Waitlist deletes the entry, the unclaimed
  # UserProfile and the Guardian.
  defp hard_delete(%WaitlistEntry{} = entry, intakes, reading) do
    outcome = invitation_outcome(entry)

    with {:ok, anonymised} <- anonymise_intakes(intakes, outcome, reading),
         {_count, _rows} <-
           Repo.update_all(from(f in CarriedFee, where: f.waitlist_id == ^entry.id),
             set: [waitlist_id: nil, updated_at: reading.now]
           ),
         :ok <- Waitlist.hard_delete(entry.id) do
      {:ok, anonymised}
    end
  end

  defp invitation_outcome(%WaitlistEntry{status: "invited"}), do: "invited"
  defp invitation_outcome(%WaitlistEntry{status: "joined"}), do: "joined"
  defp invitation_outcome(%WaitlistEntry{}), do: "not_invited"

  defp anonymise_intakes(intakes, outcome, reading) do
    Enum.reduce_while(intakes, {:ok, 0}, fn intake, {:ok, count} ->
      recorded = if intake.state == "attended", do: outcome

      case intake |> Intake.anonymise_changeset(recorded, reading.now) |> persist() do
        {:ok, _intake} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp deleted_view(entry, anonymised, fee, outcome) do
    %{
      waitlist_id: entry.id,
      anonymised_intakes: anonymised,
      carried_fee: fee && Map.take(fee, [:id, :status]),
      outcome: outcome
    }
  end

  # ── Carried Fees (ALE-388) ──────────────────────────────────────

  # The person's live (`held` or `applied`) Carried Fee: at most one.
  defp live_fee_query(waitlist_id),
    do:
      from(f in CarriedFee,
        where: f.waitlist_id == ^waitlist_id and f.status in ^CarriedFee.live_statuses()
      )

  # The Carried Fee level for a command that locked an Intake.
  defp locked_intake_fee(%{intake: %Intake{waitlist_id: id}}) when is_binary(id),
    do: live_fee_query(id)

  defp locked_intake_fee(_locked), do: nil

  defp held?(%CarriedFee{status: "held"}), do: true
  defp held?(_no_held_fee), do: false

  # Unlocked: which Contact email a person gets. Every writer of a fee holds
  # the person's entry or Intake lock, which the Contact paths hold too.
  defp held_fee?(waitlist_id),
    do:
      Repo.exists?(
        from(f in CarriedFee, where: f.waitlist_id == ^waitlist_id and f.status == "held")
      )

  defp carry_fee(
         %Intake{paid_via: "carried_fee", carried_fee_id: id, id: intake_id},
         %{
           carried_fee: %CarriedFee{id: id, status: "applied", applied_intake_id: intake_id} = fee
         },
         reading
       ),
       do:
         transition(:carried_fee, fee, CarriedFee.status_changeset(fee, "held", nil, reading.now))

  # The payment that paid it is locked by the command (`paying_payment/1`).
  defp carry_fee(%Intake{paid_via: "stripe"} = intake, %{carried_fee: nil} = locked, reading) do
    case locked.payment do
      nil ->
        {:error, :payment_not_found}

      payment ->
        %{
          waitlist_id: intake.waitlist_id,
          payment_id: payment.id,
          amount_cents: payment.amount_received_cents || payment.amount_cents,
          currency: payment.currency_received || payment.currency,
          status_changed_at: reading.now
        }
        |> CarriedFee.deferral_changeset()
        |> persist()
    end
  end

  # A Carried-Fee-paid Intake whose fee moved on, or a Stripe payer who
  # somehow already holds one: the table has no move for it.
  defp carry_fee(_intake, _locked, _reading), do: {:error, :illegal_transition}

  # The person's own confirm from their Intake page: the console command's
  # rule and act, with no actor and no note.
  defp confirm_by_link(token, clock) do
    with {:ok, peek} <- peek_intake(token),
         {:ok, %{outcome: outcome}} <-
           transact(fn ->
             peek
             |> intake_spec(nil)
             |> Map.put(:carried_fee, &locked_intake_fee/1)
             |> with_locked(
               &intake_command_locked(&1, :confirm, %{actor: nil, note: nil, options: %{}}, clock)
             )
           end) do
      {:ok, %{outcome: outcome}}
    end
  end

  # The Waitlist spreadsheet import's Paid cell (ALE-376): a `held` fee whose
  # original payment is the imported record. Runs inside the import row's
  # transaction; a person who already holds a live fee keeps it.
  defp import_carried_fee(waitlist_id, paid_text, clock) do
    with {:ok, waitlist_id} <- cast_id(waitlist_id) do
      transact(fn ->
        with_locked(
          %{
            waitlist_entry: required(from(e in WaitlistEntry, where: e.id == ^waitlist_id)),
            carried_fee: live_fee_query(waitlist_id)
          },
          &import_fee_locked(&1, paid_text, clock)
        )
      end)
    end
  end

  defp import_fee_locked(%{carried_fee: %CarriedFee{} = fee}, _paid_text, _clock),
    do: {:ok, %{outcome: :already_held, id: fee.id, status: fee.status}}

  defp import_fee_locked(%{waitlist_entry: entry}, paid_text, clock) do
    with {:ok, fee} <-
           %{
             waitlist_id: entry.id,
             imported_paid_text: paid_text,
             status_changed_at: Clock.read(clock).now
           }
           |> CarriedFee.import_changeset()
           |> persist() do
      {:ok, %{outcome: :created, id: fee.id, status: fee.status}}
    end
  end

  # ── Carried Fee refunds and forfeits (ALE-389) ─────────────────

  # Refunds a live Carried Fee under its lock: the refund row (the one
  # `insert_refund/4`, against the fee's original payment, recorded on
  # `intake`) and the fee `refunded` — the obligation is recorded, so the
  # fee is no longer held. A failed refund holds it again
  # (`hold_fee_again/3`). No fee: nothing to refund.
  defp refund_fee(nil, _intake, _actor, _reason, _reading), do: {:ok, nil}

  defp refund_fee(%CarriedFee{status: status} = fee, intake, actor, reason, reading)
       when status in ["held", "applied"] do
    with {:ok, refund} <-
           insert_refund(
             {:carried_fee, fee, original_payment(fee), intake},
             reason,
             actor,
             reading
           ),
         {:ok, _fee} <-
           transition(
             :carried_fee,
             fee,
             CarriedFee.status_changeset(fee, "refunded", fee.applied_intake_id, reading.now)
           ) do
      {:ok, refund}
    end
  end

  defp refund_fee(%CarriedFee{}, _intake, _actor, _reason, _reading),
    do: {:error, :carried_fee_not_held}

  # A deferral's fee points at its Intake payment row, which is never
  # edited, so it is read without a lock.
  defp original_payment(%CarriedFee{payment_id: nil}), do: nil
  defp original_payment(%CarriedFee{payment_id: id}), do: Repo.get!(IntakePayment, id)

  defp forfeit_fee(nil, _reading), do: {:ok, nil}

  defp forfeit_fee(%CarriedFee{} = fee, reading),
    do:
      transition(
        :carried_fee,
        fee,
        CarriedFee.status_changeset(fee, "forfeited", fee.applied_intake_id, reading.now)
      )

  # `refund_carried_fee`: a `held` fee of someone who has not attended — a
  # waiting person (with or without a contacted Intake) or one removed
  # within the 3-month retention window.
  defp refund_held_fee(entry, fee, intake, actor, reading) do
    with :ok <- may_refund_fee(entry, reading) do
      case fee do
        %CarriedFee{status: "held"} ->
          refund_fee(fee, intake, actor, "carried_fee_refunded", reading)

        %CarriedFee{status: "applied"} ->
          {:error, :carried_fee_applied}

        nil ->
          {:error, :no_carried_fee}
      end
    end
  end

  defp may_refund_fee(nil, _reading), do: {:error, :person_not_found}
  defp may_refund_fee(%WaitlistEntry{status: "waiting"}, _reading), do: :ok

  defp may_refund_fee(%WaitlistEntry{status: "removed", removed_at: %DateTime{} = at}, reading),
    do: if(Waitlist.restorable?(at, reading.now), do: :ok, else: {:error, :fee_not_refundable})

  defp may_refund_fee(%WaitlistEntry{}, _reading), do: {:error, :fee_not_refundable}

  # The Waitlist tab names the person. With an open Intake this is exactly
  # the console's `refund_carried_fee` on it (same locks, rule and history
  # row); without one the fee alone is refunded under the person's entry
  # lock, the refund recorded on the fee's original Intake (if any). The
  # open Intake is peeked unlocked, so one created meanwhile makes the
  # attempt retry from a fresh peek — the `withdraw_person/4` shape.
  defp refund_person_fee(principal_id, waitlist_id, attrs, clock) do
    with {:ok, context} <- intake_command_context(:refund_carried_fee, principal_id, attrs),
         {:ok, waitlist_id} <- cast_person_id(waitlist_id) do
      refund_person_fee_attempt(waitlist_id, context, clock, @batch_attempts)
    end
  end

  defp refund_person_fee_attempt(waitlist_id, context, clock, attempts) do
    case transact(fn -> refund_person_fee_locked(waitlist_id, context, clock) end) do
      {:error, :concurrent_change} when attempts > 1 ->
        refund_person_fee_attempt(waitlist_id, context, clock, attempts - 1)

      result ->
        result
    end
  end

  defp refund_person_fee_locked(waitlist_id, context, clock) do
    case peek_open_intake(waitlist_id) do
      nil ->
        with_locked(
          %{
            waitlist_entry: from(e in WaitlistEntry, where: e.id == ^waitlist_id),
            carried_fee: live_fee_query(waitlist_id)
          },
          &refund_fee_alone(&1, waitlist_id, context, clock)
        )

      peek ->
        with_locked(
          intake_command_spec(:refund_carried_fee, peek),
          &refund_open_intake_fee(&1, waitlist_id, context, clock)
        )
    end
  end

  # The peeked Intake must still be this person's open one under the lock.
  defp refund_open_intake_fee(locked, waitlist_id, context, clock) do
    with true <- open_intake_of?(locked, waitlist_id) || {:error, :concurrent_change},
         {:ok, view} <- intake_command_locked(locked, :refund_carried_fee, context, clock) do
      {:ok, fee_command_view(waitlist_id, view)}
    end
  end

  defp refund_fee_alone(%{waitlist_entry: entry, carried_fee: fee}, waitlist_id, context, clock) do
    reading = Clock.read(clock)

    with true <- peek_open_intake(waitlist_id) == nil || {:error, :concurrent_change},
         {:ok, refund} <- refund_held_fee(entry, fee, nil, context.actor, reading),
         :ok <-
           queue_person_notice(
             entry,
             refund.intake_id,
             "carried_fee_refunded",
             "carried_fee_refunded:#{refund.id}",
             %{
               "firstName" => first_name_of(entry.id),
               "refundAmount" => refund_amount(refund)
             },
             reading
           ) do
      {:ok, fee_command_view(waitlist_id, nil)}
    end
  end

  defp fee_command_view(waitlist_id, intake_view) do
    fee =
      Repo.one(
        from(f in CarriedFee,
          where: f.waitlist_id == ^waitlist_id,
          order_by: [desc: f.status_changed_at, desc: f.created_at],
          limit: 1
        )
      )

    %{
      waitlist_id: waitlist_id,
      carried_fee: fee && Map.take(fee, [:id, :status]),
      intake: intake_view,
      outcome: :done
    }
  end

  # A notice to a person outside any one Intake's own command (the
  # Waitlist tab's Carried Fee and withdraw paths), logged on `intake_id`
  # when there is an Intake it belongs with. An anonymised person is not
  # emailed.
  defp queue_person_notice(
         %WaitlistEntry{email: email} = entry,
         intake_id,
         type,
         occasion,
         values,
         reading
       )
       when is_binary(email) do
    with {:ok, _job} <- IntakeEmails.queue(type, entry, values) do
      log_person_notice(intake_id, type, occasion, reading)
    end
  end

  defp queue_person_notice(_anonymised, _intake_id, _type, _occasion, _values, _reading), do: :ok

  defp log_person_notice(nil, _type, _occasion, _reading), do: :ok

  defp log_person_notice(intake_id, type, occasion, reading) do
    with {:ok, _log} <-
           %{intake_id: intake_id, email_type: type, occasion: occasion, queued_at: reading.now}
           |> IntakeEmailLog.changeset()
           |> persist(),
         do: :ok
  end

  # `link_carried_fee_payment`: an imported Carried Fee (no payment this
  # system made) linked to the Stripe payment the person originally paid
  # with, by PaymentIntent id. Stripe is read between transactions — the
  # amount is what Stripe says the payment took, never typed in — and the
  # link written under the person's entry → Carried Fee locks after a
  # re-read. Once linked the fee refunds through Stripe like a deferral's.
  defp link_fee_payment(waitlist_id, attrs, clock) do
    with {:ok, waitlist_id} <- cast_person_id(waitlist_id),
         {:ok, payment_intent_id} <- payment_intent_reference(attrs),
         {:ok, peek} <- peek_linkable_fee(waitlist_id, payment_intent_id) do
      link_peeked_fee(peek, waitlist_id, payment_intent_id, clock)
    end
  end

  defp link_peeked_fee({:linked, fee}, _waitlist_id, _id, _clock),
    do: {:ok, linked_fee_view(fee, :already_done)}

  defp link_peeked_fee({:link, _fee}, waitlist_id, payment_intent_id, clock) do
    with {:ok, payment} <- IntakeRefunds.original_payment(payment_intent_id) do
      transact(fn ->
        with_locked(
          %{
            waitlist_entry: required(from(e in WaitlistEntry, where: e.id == ^waitlist_id)),
            carried_fee: live_fee_query(waitlist_id)
          },
          &link_fee_locked(&1, payment_intent_id, payment, clock)
        )
      end)
    end
  end

  defp payment_intent_reference(attrs) do
    case fetch_attr(attrs, :payment_intent_id) do
      id when is_binary(id) ->
        id = String.trim(id)

        if Regex.match?(~r/\Api_[A-Za-z0-9_-]{1,250}\z/, id),
          do: {:ok, id},
          else: {:error, :invalid_payment_reference}

      _missing ->
        {:error, :invalid_payment_reference}
    end
  end

  defp peek_linkable_fee(waitlist_id, payment_intent_id) do
    case Repo.one(live_fee_query(waitlist_id)) do
      nil -> {:error, :no_carried_fee}
      fee -> linkable(fee, payment_intent_id)
    end
  end

  defp linkable(%CarriedFee{origin: "deferral"}, _id), do: {:error, :not_imported}
  defp linkable(%CarriedFee{stripe_payment_intent_id: id} = fee, id), do: {:ok, {:linked, fee}}

  defp linkable(%CarriedFee{stripe_payment_intent_id: nil} = fee, payment_intent_id) do
    if Repo.exists?(
         from(p in IntakePayment, where: p.stripe_payment_intent_id == ^payment_intent_id)
       ),
       do: {:error, :payment_already_linked},
       else: {:ok, {:link, fee}}
  end

  defp linkable(%CarriedFee{}, _other_id), do: {:error, :already_linked}

  defp link_fee_locked(%{carried_fee: nil}, _id, _payment, _clock), do: {:error, :no_carried_fee}

  defp link_fee_locked(%{carried_fee: fee}, payment_intent_id, payment, _clock) do
    case linkable(fee, payment_intent_id) do
      {:ok, {:linked, fee}} ->
        {:ok, linked_fee_view(fee, :already_done)}

      {:ok, {:link, fee}} ->
        with {:ok, fee} <-
               fee
               |> CarriedFee.link_changeset(payment_intent_id, payment.amount, payment.currency)
               |> persist(),
             do: {:ok, linked_fee_view(fee, :done)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp linked_fee_view(%CarriedFee{} = fee, outcome) do
    fee
    |> Map.take([:id, :waitlist_id, :status, :amount_cents, :currency, :stripe_payment_intent_id])
    |> Map.put(:outcome, outcome)
  end

  # ── check_in / undo_check_in ────────────────────────────────────

  defp door_check_in(principal_id, workshop_id, intake_id, action, clock) do
    with {:ok, workshop_id} <- cast_id(workshop_id),
         {:ok, intake_id} <- cast_id(intake_id) do
      transact(fn ->
        with_locked(
          %{
            workshop: required(from(w in BeginnersWorkshop, where: w.id == ^workshop_id)),
            intake:
              required(
                from(i in Intake, where: i.id == ^intake_id and i.workshop_id == ^workshop_id)
              )
          },
          &check_in_locked(&1, principal_id, action, clock)
        )
      end)
    end
  end

  # Staff rows change only under the workshop lock, so this re-check is
  # authoritative: someone unassigned since the pre-read check is refused.
  defp check_in_locked(%{workshop: workshop, intake: intake}, principal_id, action, clock) do
    reading = Clock.read(clock)

    with :ok <- authorize_assigned(principal_id, :"beginners.workshops.run", workshop.id),
         :ok <- check_in_window_open(workshop, reading),
         :ok <- check_in_paid(intake),
         {:ok, intake} <- record_check_in(intake, principal_id, action, reading) do
      {:ok, check_in_view(intake)}
    end
  end

  defp check_in_window_open(workshop, reading) do
    case WorkshopPolicy.check_in_window(workshop, reading) do
      :open -> :ok
      :before -> {:error, :check_in_not_open}
      :closed -> {:error, :check_in_closed}
    end
  end

  # No walk-ins: only a paid person is checked in.
  defp check_in_paid(%Intake{state: "paid"}), do: :ok
  defp check_in_paid(%Intake{}), do: {:error, :not_paid}

  defp record_check_in(%Intake{checked_in_at: %DateTime{}} = intake, _id, :check_in, _reading),
    do: {:ok, intake}

  defp record_check_in(%Intake{} = intake, principal_id, :check_in, reading),
    do: intake |> Intake.check_in_changeset(principal_id, reading.now) |> persist()

  defp record_check_in(%Intake{checked_in_at: nil} = intake, _id, :undo, _reading),
    do: {:ok, intake}

  defp record_check_in(%Intake{} = intake, _id, :undo, _reading),
    do: intake |> Intake.undo_check_in_changeset() |> persist()

  defp check_in_view(%Intake{} = intake),
    do: Map.take(intake, [:id, :workshop_id, :checked_in_at, :checked_in_by_principal_id])

  # ── pass_payment_cutoff ─────────────────────────────────────────

  # Under the workshop lock: the Waitlist entries of its `contacted` people
  # (whose standing a lapse changes). Nothing is locked before the cutoff.
  defp cutoff_entries(%{workshop: workshop}, clock) do
    if cutoff_due?(workshop, Clock.read(clock)) do
      contacted =
        from(i in Intake,
          where: i.workshop_id == ^workshop.id and i.state == "contacted",
          select: i.waitlist_id
        )

      {:all, from(e in WaitlistEntry, where: e.id in subquery(contacted))}
    end
  end

  # The workshop's open Intakes, once its entries are locked.
  defp cutoff_intakes(%{workshop: workshop, waitlist_entry: entries}) when is_list(entries) do
    open = Intake.open_states()
    {:all, from(i in Intake, where: i.workshop_id == ^workshop.id and i.state in ^open)}
  end

  defp cutoff_intakes(_locked), do: nil

  # The `held` Carried Fees of the contacted people: they may still confirm
  # after the cutoff (ALE-388), so the pass leaves their Intakes open.
  defp held_fees_of_contacted(%{workshop: workshop, intake: intakes}) when is_list(intakes) do
    contacted =
      from(i in Intake,
        where: i.workshop_id == ^workshop.id and i.state == "contacted",
        select: i.waitlist_id
      )

    {:all,
     from(f in CarriedFee, where: f.status == "held" and f.waitlist_id in subquery(contacted))}
  end

  defp held_fees_of_contacted(_locked), do: nil

  # Its live Seat Holds: an Intake holding one is left for Stripe to settle.
  defp cutoff_holds(%{workshop: workshop, intake: intakes}) when is_list(intakes),
    do:
      {:all,
       from(p in IntakePayment, where: p.workshop_id == ^workshop.id and p.status == "open")}

  defp cutoff_holds(_locked), do: nil

  defp cutoff_due?(workshop, reading),
    do: workshop.status == "scheduled" and not WorkshopPolicy.payment_open?(workshop, reading)

  defp pass_cutoff_locked(%{intake: nil}, _clock), do: {:ok, %{outcome: :not_due}}

  defp pass_cutoff_locked(locked, clock) do
    %{workshop: workshop, waitlist_entry: entries, intake: intakes, payment: holds} = locked
    reading = Clock.read(clock)

    if cutoff_due?(workshop, reading) do
      pass = %{
        workshop: workshop,
        facts: facts_for(workshop),
        held: MapSet.new(holds, & &1.intake_id),
        entries: Map.new(entries, &{&1.id, &1}),
        fee_holders: MapSet.new(locked.carried_fee, & &1.waitlist_id),
        reading: reading
      }

      tally = %{outcome: :passed, pre_workshop: 0, lapsed: 0, returned: 0, awaiting_hold: 0}

      Enum.reduce_while(intakes, {:ok, tally}, fn intake, {:ok, tally} ->
        intake
        |> pass_intake(pass)
        |> count_passed(tally)
      end)
    else
      {:ok, %{outcome: :not_due}}
    end
  end

  defp count_passed({:ok, nil}, tally), do: {:cont, {:ok, tally}}

  defp count_passed({:ok, counted}, tally),
    do: {:cont, {:ok, Map.update!(tally, counted, &(&1 + 1))}}

  defp count_passed({:error, reason}, _tally), do: {:halt, {:error, reason}}

  defp pass_intake(%Intake{state: "paid"} = intake, %{workshop: workshop, reading: reading}) do
    case queue_pre_workshop(intake, workshop, reading) do
      {:ok, :queued} -> {:ok, :pre_workshop}
      {:ok, :not_owed} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp pass_intake(%Intake{state: "contacted"} = intake, pass) do
    if MapSet.member?(pass.fee_holders, intake.waitlist_id),
      do: {:ok, nil},
      else: settle_at_cutoff(intake, pass)
  end

  defp settle_at_cutoff(intake, pass) do
    hold_live? = MapSet.member?(pass.held, intake.id)

    case {entry_of(intake, pass.entries),
          WorkshopPolicy.cutoff_settlement(hold_live?, pass.workshop, pass.facts)} do
      # A person contacted after this pass peeked the entries: the next sweep.
      {:not_locked, _settlement} -> {:ok, nil}
      {_entry, :await_hold} -> {:ok, :awaiting_hold}
      {entry, :lapse} -> lapse(intake, entry)
      {_entry, :return} -> close(intake, "returned", :returned)
    end
  end

  defp entry_of(%Intake{waitlist_id: nil}, _entries), do: nil
  defp entry_of(%Intake{waitlist_id: id}, entries), do: Map.get(entries, id, :not_locked)

  # A lapse removes a waiting person (story 86). A person staff already
  # removed stays removed; an anonymised one has no standing.
  defp lapse(intake, %WaitlistEntry{status: "waiting", id: id}) do
    with {:ok, counted} <- close(intake, "lapsed", :lapsed),
         {:ok, _entry} <- Waitlist.change_standing(id, "removed"),
         do: {:ok, counted}
  end

  defp lapse(intake, _entry), do: close(intake, "lapsed", :lapsed)

  # A return leaves the standing alone: a contacted person is still
  # `waiting`, and their priority date was never touched (story 87).
  defp close(intake, state, counted) do
    with {:ok, _intake} <- transition(:intake, intake, Intake.close_changeset(intake, state)),
         do: {:ok, counted}
  end

  # ── finish_workshop / finalise_attendance ───────────────────────

  defp finalise(workshop_id, by, clock) do
    with {:ok, workshop_id} <- cast_id(workshop_id) do
      transact(fn ->
        with_locked(
          %{
            workshop: required(from(w in BeginnersWorkshop, where: w.id == ^workshop_id)),
            waitlist_entry: &finalise_entries(&1, by, clock),
            intake: &finalise_intakes/1,
            carried_fee: &applied_fees/1,
            payment: &cutoff_holds/1
          },
          &finalise_locked(&1, by, clock)
        )
      end)
    end
  end

  # Under the workshop lock: the Waitlist entries of its open Intakes (whose
  # standing finalisation changes). Nothing more is locked when it may not
  # finalise now.
  defp finalise_entries(%{workshop: workshop}, by, clock) do
    if may_finalise?(workshop, by, Clock.read(clock)) do
      open =
        from(i in Intake,
          where: i.workshop_id == ^workshop.id and i.state in ^Intake.open_states(),
          select: i.waitlist_id
        )

      {:all, from(e in WaitlistEntry, where: e.id in subquery(open))}
    end
  end

  defp finalise_intakes(%{workshop: workshop, waitlist_entry: entries}) when is_list(entries),
    do:
      {:all,
       from(i in Intake,
         where: i.workshop_id == ^workshop.id and i.state in ^Intake.open_states()
       )}

  defp finalise_intakes(_locked), do: nil

  # The Carried Fees applied to the workshop's paid Intakes: spent on
  # attendance, forfeited on a no-show (ALE-367).
  defp applied_fees(%{workshop: workshop, intake: intakes}) when is_list(intakes) do
    paid =
      from(i in Intake,
        where: i.workshop_id == ^workshop.id and i.state == "paid",
        select: i.id
      )

    {:all,
     from(f in CarriedFee, where: f.status == "applied" and f.applied_intake_id in subquery(paid))}
  end

  defp applied_fees(_locked), do: nil

  defp may_finalise?(workshop, {:staff, _id}, reading),
    do: WorkshopPolicy.finish_allowed?(workshop, reading)

  defp may_finalise?(workshop, :system, reading),
    do: WorkshopPolicy.finalisation_due?(workshop, reading)

  defp finalise_locked(locked, by, clock) do
    reading = Clock.read(clock)
    workshop = locked.workshop

    with :ok <- finalise_authorized(by, workshop),
         :ok <- finalisable(workshop, by, reading) do
      finalise_now(locked, by, reading)
    end
  end

  defp finalise_now(locked, by, reading) do
    workshop = locked.workshop

    pass = %{
      workshop: workshop,
      facts: facts_for(workshop),
      held: MapSet.new(locked.payment, & &1.intake_id),
      entries: Map.new(locked.waitlist_entry, &{&1.id, &1}),
      fees: Map.new(locked.carried_fee || [], &{&1.applied_intake_id, &1}),
      reading: reading
    }

    if Enum.any?(locked.intake, &awaiting_hold?(&1, pass)),
      do: awaiting_hold(by),
      else: finalise_all(locked.intake, pass, by)
  end

  # Staff rows change only under the workshop lock, so this re-check is
  # authoritative (as for check-in).
  defp finalise_authorized({:staff, principal_id}, workshop),
    do: authorize_assigned(principal_id, :"beginners.workshops.run", workshop.id)

  defp finalise_authorized(:system, _workshop), do: :ok

  # The pass answers "not due" (it runs every sweep); Staff get a refusal.
  defp finalisable(workshop, by, reading) do
    cond do
      may_finalise?(workshop, by, reading) -> :ok
      by == :system -> {:ok, %{outcome: :not_due}}
      workshop.status != "scheduled" -> still_scheduled(workshop)
      true -> {:error, :check_in_not_open}
    end
  end

  # The cutoff rule leaves an Intake whose own Seat Hold is live for Stripe
  # to settle; finalisation waits for it rather than close a workshop with
  # someone mid-checkout.
  defp awaiting_hold?(%Intake{state: "contacted"} = intake, pass),
    do:
      WorkshopPolicy.cutoff_settlement(
        MapSet.member?(pass.held, intake.id),
        pass.workshop,
        pass.facts
      ) ==
        :await_hold

  defp awaiting_hold?(%Intake{}, _pass), do: false

  defp awaiting_hold({:staff, _id}), do: {:error, :payment_in_progress}
  defp awaiting_hold(:system), do: {:ok, %{outcome: :awaiting_hold}}

  defp finalise_all(intakes, pass, by) do
    tally = %{outcome: :finalised, attended: 0, no_show: 0, lapsed: 0, returned: 0}

    with {:ok, tally} <-
           Enum.reduce_while(intakes, {:ok, tally}, fn intake, {:ok, tally} ->
             intake |> finalise_intake(pass) |> count_passed(tally)
           end),
         :ok <- freeze_staff(pass.workshop),
         {:ok, _workshop} <-
           transition(
             :workshop,
             pass.workshop,
             BeginnersWorkshop.finalise_changeset(pass.workshop, finaliser(by), pass.reading.now)
           ) do
      {:ok, tally}
    end
  end

  defp finaliser({:staff, principal_id}), do: principal_id
  defp finaliser(:system), do: nil

  # The check-in record decides: in → `attended`, not in → `no_show`
  # (standing `removed`, story 104, with no email). A person contacted
  # after the entries were locked cannot exist after the cutoff, so an
  # unlocked entry is a race: roll back and let the next attempt decide.
  defp finalise_intake(%Intake{state: "paid"} = intake, pass) do
    case entry_of(intake, pass.entries) do
      :not_locked ->
        {:error, :concurrent_change}

      entry ->
        {state, counted, standing} =
          if intake.checked_in_at,
            do: {"attended", :attended, "attended"},
            else: {"no_show", :no_show, "removed"}

        with {:ok, counted} <- close(intake, state, counted),
             {:ok, _entry} <- follow_standing(entry, standing),
             {:ok, _fee} <- end_fee(Map.get(pass.fees, intake.id), state, pass.reading),
             do: {:ok, counted}
    end
  end

  # Finalisation also closes any Intake still `contacted` by the cutoff rule
  # (the live-hold case never reaches here).
  defp finalise_intake(%Intake{state: "contacted"} = intake, pass) do
    case {entry_of(intake, pass.entries),
          WorkshopPolicy.cutoff_settlement(false, pass.workshop, pass.facts)} do
      {:not_locked, _settlement} -> {:error, :concurrent_change}
      {entry, :lapse} -> lapse(intake, entry)
      {_entry, :return} -> close(intake, "returned", :returned)
    end
  end

  defp end_fee(nil, _state, _reading), do: {:ok, nil}

  defp end_fee(%CarriedFee{} = fee, state, reading) do
    status = if state == "attended", do: "spent", else: "forfeited"

    transition(
      :carried_fee,
      fee,
      CarriedFee.status_changeset(fee, status, fee.applied_intake_id, reading.now)
    )
  end

  # An anonymised person has no standing; one whose standing already moved
  # (a coordinator removed them, say) keeps it unless the table allows the
  # change.
  defp follow_standing(nil, _to), do: {:ok, nil}

  defp follow_standing(%WaitlistEntry{status: from} = entry, to) do
    if Standing.allowed?(from, to),
      do: Waitlist.change_standing(entry.id, to),
      else: {:ok, entry}
  end

  # The Staff list freezes as the permanent record (story 18): each row
  # keeps the name the person had at finalisation.
  defp freeze_staff(%BeginnersWorkshop{} = workshop) do
    names =
      from(s in StaffAssignment,
        left_join: p in UserProfile,
        on: p.principal_id == s.principal_id,
        where: s.workshop_id == ^workshop.id,
        select: {s, p.first_name, p.last_name}
      )
      |> Repo.all()

    Enum.reduce_while(names, :ok, fn {row, first, last}, :ok ->
      name = row.frozen_name || WorkshopFacts.display_name(first, last)

      case row |> StaffAssignment.freeze_changeset(name) |> persist() do
        {:ok, _row} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # ── send_follow_ups ─────────────────────────────────────────────

  defp follow_up_intakes(%{workshop: workshop}, clock) do
    if WorkshopPolicy.follow_up_due?(workshop, Clock.read(clock)),
      do:
        {:all, from(i in Intake, where: i.workshop_id == ^workshop.id and i.state == "attended")}
  end

  defp follow_ups_locked(%{intake: nil}, _clock), do: {:ok, %{outcome: :not_due}}

  defp follow_ups_locked(%{workshop: workshop, intake: intakes}, clock) do
    reading = Clock.read(clock)

    if WorkshopPolicy.follow_up_due?(workshop, reading),
      do:
        Enum.reduce_while(
          intakes,
          {:ok, %{outcome: :sent, follow_ups: 0}},
          &follow_up(&1, &2, workshop, reading)
        ),
      else: {:ok, %{outcome: :not_due}}
  end

  defp follow_up(intake, {:ok, tally}, workshop, reading) do
    case queue_follow_up(intake, workshop, reading) do
      {:ok, :queued} -> {:cont, {:ok, Map.update!(tally, :follow_ups, &(&1 + 1))}}
      {:ok, :not_owed} -> {:cont, {:ok, tally}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  # "Follow-up", once per Intake: every writer of it holds the workshop
  # lock, so the log row read here cannot appear concurrently; the unique
  # `occasion` index is the backstop. An anonymised person is owed nothing.
  defp queue_follow_up(%Intake{waitlist_id: nil}, _workshop, _reading), do: {:ok, :not_owed}

  defp queue_follow_up(intake, workshop, reading),
    do:
      queue_once(
        intake,
        "follow_up",
        "follow_up",
        &%{"firstName" => &1, "date" => Values.date(workshop.date)},
        reading
      )

  # ── invite ──────────────────────────────────────────────────────

  # The Follow-up does not gate an Invitation (story 107): attendance being
  # final is enough.
  defp invite_locked(%{workshop: workshop, waitlist_entry: entry, intake: intake}, actor_id) do
    with :ok <- invite_finalised(workshop),
         :ok <- invite_attended(intake),
         {:ok, entry} <- invitable(entry),
         {:ok, invite} <- invite_details(entry),
         {:ok, %{invitation_id: invitation_id}} <- issue_invitation(invite, entry, actor_id),
         {:ok, entry} <- Waitlist.change_standing(entry.id, "invited") do
      {:ok,
       %{
         intake_id: intake.id,
         workshop_id: workshop.id,
         waitlist_id: entry.id,
         invitation_id: invitation_id,
         standing: entry.status
       }}
    end
  end

  defp invite_finalised(%BeginnersWorkshop{status: "finalised"}), do: :ok
  defp invite_finalised(%BeginnersWorkshop{}), do: {:error, :not_finalised}

  defp invite_attended(%Intake{state: "attended"}), do: :ok
  defp invite_attended(%Intake{}), do: {:error, :not_attended}

  # An anonymised person has no entry, and nobody to invite.
  defp invitable(nil), do: {:error, :person_not_found}
  defp invitable(%WaitlistEntry{status: "attended"} = entry), do: {:ok, entry}
  defp invitable(%WaitlistEntry{status: "invited"}), do: {:error, :already_invited}
  defp invitable(%WaitlistEntry{status: "joined"}), do: {:error, :already_joined}
  defp invitable(%WaitlistEntry{}), do: {:error, :not_invitable}

  # The Invitation carries the Waitlist profile's details, read under the
  # entry lock (the profile is the entry's and changes with it).
  defp invite_details(%WaitlistEntry{email: nil}), do: {:error, :person_not_found}

  defp invite_details(%WaitlistEntry{id: id, email: email}) do
    case Repo.one(from(p in UserProfile, where: p.waitlist_id == ^id)) do
      nil ->
        {:error, :person_not_found}

      profile ->
        {:ok,
         %{
           "firstName" => profile.first_name,
           "lastName" => profile.last_name,
           "email" => email,
           "phoneNumber" => profile.phone_number,
           "dateOfBirth" => profile.date_of_birth,
           "pricingTier" => "standard",
           "invitationType" => "beginners_workshop"
         }}
    end
  end

  # Onboarding's refusals carry the email out of the rolled-back
  # transaction, so `record_invite_refusal/2` can log them.
  defp issue_invitation(invite, entry, actor_id) do
    case Onboarding.issue_invitation(invite, actor_id, waitlist_id: entry.id) do
      {:ok, issued} -> {:ok, issued}
      {:error, reason} -> {:error, {:invitation_refused, invite["email"], reason}}
    end
  end

  defp record_invite_refusal({:error, {:invitation_refused, email, reason}}, actor_id) do
    _ = Onboarding.record_refused_invitation(email, reason, actor_id)
    {:error, invitation_refusal(reason)}
  end

  defp record_invite_refusal(result, _actor_id), do: result

  defp invitation_refusal(:duplicate_pending_invitation), do: :email_has_pending_invitation
  defp invitation_refusal(:email_is_principal), do: :email_is_principal
  defp invitation_refusal(:email_on_waitlist), do: :email_on_waitlist
  defp invitation_refusal({:invalid_invite, _fields}), do: :incomplete_details
  # A racing issue for the same email loses on the pending-email index.
  defp invitation_refusal(_reason), do: :concurrent_change

  # ── set_staff ───────────────────────────────────────────────────

  defp set_staff_locked(%{workshop: workshop}, staff, actor_id, clock) do
    # Staff can change at any time before Attendance Finalisation (story 17);
    # the Staff list of a finalised workshop is its permanent record.
    with :ok <- still_scheduled(workshop),
         {:ok, created} <- apply_staff(workshop, current_staff(workshop), staff, actor_id) do
      {:ok, {WorkshopProjection.view(workshop, facts_for(workshop), Clock.read(clock)), created}}
    end
  end

  # Read under the workshop lock: no other writer can touch these rows.
  defp current_staff(%BeginnersWorkshop{id: id}),
    do: Repo.all(from(s in StaffAssignment, where: s.workshop_id == ^id))

  # `%{coach: id | nil, assistants: [id]}` from the command's attributes. A
  # person picked as coach is dropped from the assistants (story 14).
  defp staff_input(attrs) do
    coach = fetch_attr(attrs, :coach_principal_id)
    assistants = fetch_attr(attrs, :assistant_principal_ids) || []

    with {:ok, coach} <- cast_optional_id(coach),
         true <- is_list(assistants),
         {:ok, assistants} <- cast_ids(assistants) do
      {:ok, %{coach: coach, assistants: assistants |> Enum.uniq() |> List.delete(coach)}}
    else
      _ -> {:error, :invalid_staff}
    end
  end

  defp fetch_attr(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp cast_optional_id(nil), do: {:ok, nil}
  defp cast_optional_id(""), do: {:ok, nil}
  defp cast_optional_id(id) when is_binary(id), do: Ecto.UUID.cast(id)
  defp cast_optional_id(_id), do: :error

  defp cast_ids(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case cast_optional_id(id) do
        {:ok, id} when is_binary(id) -> {:cont, {:ok, [id | acc]}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      :error -> :error
    end
  end

  # Replaces the workshop's Staff with `staff`. Only a *new* role is checked:
  # a coach must hold `beginners.workshops.lead` and an assistant must be an
  # active Member at assignment, so a coach who later loses the coach role
  # keeps the assignment (story 24). A change of role is a removed row and a
  # new one. Returns the Notifications to signal after commit.
  defp apply_staff(workshop, current, staff, actor_id) do
    desired =
      Map.new(staff.assistants, &{&1, "assistant"})
      |> then(&if(staff.coach, do: Map.put(&1, staff.coach, "coach"), else: &1))

    held = Map.new(current, &{&1.principal_id, &1.role})
    added = for {id, role} <- desired, Map.get(held, id) != role, do: {id, role}
    stale = Enum.filter(current, &(Map.get(desired, &1.principal_id) != &1.role))

    with :ok <- eligible(added, "coach", :"beginners.workshops.lead", :not_a_coach),
         :ok <-
           eligible(added, "assistant", :"beginners.workshops.assigned.read", :not_a_member),
         :ok <- delete_staff(stale),
         {:ok, inserted} <- insert_staff(workshop, added, actor_id) do
      removed = Enum.reject(stale, &Map.has_key?(desired, &1.principal_id))

      notify_staff(
        workshop,
        Enum.map(inserted, &{:assigned, &1}) ++ Enum.map(removed, &{:unassigned, &1}),
        actor_id
      )
    end
  end

  defp eligible(added, role, capability, refusal) do
    ids = for {id, ^role} <- added, do: id

    if ids == [] or
         length(Capabilities.principal_ids_with(capability, only: ids)) == length(ids),
       do: :ok,
       else: {:error, refusal}
  end

  defp delete_staff([]), do: :ok

  defp delete_staff(rows) do
    ids = Enum.map(rows, & &1.id)
    {_count, _} = Repo.delete_all(from(s in StaffAssignment, where: s.id in ^ids))
    :ok
  end

  # Eligibility was checked and stale rows deleted before this runs, so the
  # one-coach index never sees two coaches. Sorted only for a stable order.
  defp insert_staff(workshop, added, actor_id) do
    added
    |> Enum.sort_by(fn {id, role} -> {role == "coach", id} end)
    |> Enum.reduce_while({:ok, []}, fn {id, role}, {:ok, acc} ->
      %{
        workshop_id: workshop.id,
        principal_id: id,
        role: role,
        assigned_by_principal_id: actor_id
      }
      |> StaffAssignment.changeset()
      |> persist()
      |> case do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # One keyed Notification per assignment row and event, so assigning,
  # removing and assigning the same person again notifies each time, and a
  # retried command never twice. The person making the change already knows.
  defp notify_staff(workshop, events, actor_id) do
    events
    |> Enum.reject(fn {_event, row} -> row.principal_id == actor_id end)
    |> Enum.map(fn {event, row} ->
      {row.principal_id, "beginners-workshop-staff:#{row.id}:#{event}",
       staff_message(event, row.role, workshop)}
    end)
    |> create_keyed()
  end

  # Keyed Notifications inside this transaction; returns the rows created,
  # for the caller to signal after commit.
  defp create_keyed(notifications) do
    Enum.reduce_while(notifications, {:ok, []}, fn {principal_id, key, body}, {:ok, acc} ->
      case Notifications.create_keyed_in_transaction(principal_id, key, body) do
        {:ok, :created, notification} -> {:cont, {:ok, [notification | acc]}}
        {:ok, :already_created} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp staff_message(:assigned, "coach", workshop),
    do: "You're the coach for the Beginners' Workshop on #{when_where(workshop)}."

  defp staff_message(:assigned, "assistant", workshop),
    do: "You're assisting at the Beginners' Workshop on #{when_where(workshop)}."

  defp staff_message(:unassigned, _role, workshop),
    do: "You're no longer on the Staff for the Beginners' Workshop on #{when_where(workshop)}."

  defp when_where(workshop) do
    "#{Calendar.strftime(workshop.date, "%a %-d %b %Y")} at " <>
      "#{Calendar.strftime(workshop.start_time, "%H:%M")}, #{workshop.venue}"
  end

  # Signals the Notifications a committed command created (ADR 0025: the row
  # is the source of truth; the channel follows the commit).
  defp signal_after_commit({:ok, {result, created}}) do
    Enum.each(created, &Notifications.signal_created/1)
    {:ok, result}
  end

  defp signal_after_commit(error), do: error

  # ── Shared rules ────────────────────────────────────────────────

  defp resolve_cutoff(input, %{date: date, start_time: start_time}) do
    ClubCalendar.to_utc(
      Map.get(input, :payment_cutoff_date) || WorkshopPolicy.default_cutoff_date(date),
      Map.get(input, :payment_cutoff_time) || start_time
    )
  end

  defp in_future(starts_at, reading) do
    if DateTime.compare(starts_at, reading.now) == :gt, do: :ok, else: {:error, :start_in_past}
  end

  defp cutoff_before_start(cutoff, starts_at) do
    if WorkshopPolicy.cutoff_before_start?(cutoff, starts_at),
      do: :ok,
      else: {:error, :invalid_payment_cutoff}
  end

  defp contact_from_on_or_before(contact_from, cutoff) do
    if WorkshopPolicy.contact_from_valid?(contact_from, cutoff),
      do: :ok,
      else: {:error, :invalid_contact_from}
  end

  defp facts_for(%BeginnersWorkshop{id: id}), do: Map.fetch!(WorkshopFacts.load([id]), id)

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  # ── The lock primitive ──────────────────────────────────────────

  # `spec` maps lock levels to a query (`nil` skips the level), a
  # `required(query)` (a missing row is `:not_found`), `{:all, query}` (every
  # row, locked in id order) or a function of the rows locked so far. Levels
  # are always taken in `@lock_levels` order.
  defp with_locked(spec, fun) when is_map(spec) do
    case Map.keys(spec) -- @lock_levels do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown lock level(s) #{inspect(unknown)}"
    end

    @lock_levels
    |> Enum.reduce_while({:ok, %{}}, fn level, {:ok, locked} ->
      case spec |> Map.get(level) |> resolve_spec(locked) |> lock_rows() do
        {:ok, rows} -> {:cont, {:ok, Map.put(locked, level, rows)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, locked} -> fun.(locked)
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_spec(spec, locked) when is_function(spec, 1), do: spec.(locked)
  defp resolve_spec(spec, _locked), do: spec

  defp lock_rows(nil), do: {:ok, nil}

  defp lock_rows({:all, query}) do
    {:ok,
     query
     |> exclude(:order_by)
     |> order_by([row], asc: row.id)
     |> lock("FOR UPDATE")
     |> Repo.all()}
  end

  defp lock_rows({:required, query}) do
    case lock_rows(query) do
      {:ok, nil} -> {:error, :not_found}
      found -> found
    end
  end

  defp lock_rows(%Ecto.Query{} = query), do: {:ok, query |> lock("FOR UPDATE") |> Repo.one()}

  defp required(query), do: {:required, query}

  defp transact(fun) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # ── transition/3 ────────────────────────────────────────────────

  # The only writer of a status: refuses a change the table does not list,
  # then persists the changeset (which also carries the change's stamps).
  defp transition(entity, row, %Ecto.Changeset{} = changeset) do
    field = Map.fetch!(@status_fields, entity)
    from = Map.fetch!(row, field)
    to = Ecto.Changeset.get_field(changeset, field)

    if transition_allowed?(entity, from, to),
      do: persist(changeset),
      else: {:error, :illegal_transition}
  end

  # ── persist/1 ───────────────────────────────────────────────────

  defp persist(%Ecto.Changeset{data: %schema{}} = changeset) do
    changeset
    |> declare_constraints(schema)
    |> insert_or_update()
    |> case do
      {:ok, row} -> {:ok, row}
      {:error, %Ecto.Changeset{} = failed} -> {:error, constraint_reason(failed, schema)}
    end
  end

  defp insert_or_update(%Ecto.Changeset{data: %{__meta__: %{state: :built}}} = changeset),
    do: Repo.insert(changeset)

  defp insert_or_update(changeset), do: Repo.update(changeset)

  defp declare_constraints(changeset, schema) do
    changeset =
      @unique_constraints
      |> Map.get(schema, [])
      |> Enum.reduce(changeset, fn {field, name, _reason}, acc ->
        Ecto.Changeset.unique_constraint(acc, field, name: name)
      end)

    @check_constraints
    |> Map.get(schema, [])
    |> Enum.reduce(changeset, fn {field, name}, acc ->
      Ecto.Changeset.check_constraint(acc, field, name: name, message: "is invalid")
    end)
  end

  # A unique violation becomes its declared reason; anything else (field
  # validation, a check constraint) stays the changeset.
  defp constraint_reason(%Ecto.Changeset{errors: errors} = changeset, schema) do
    reasons =
      Map.new(Map.get(@unique_constraints, schema, []), fn {_f, name, reason} ->
        {name, reason}
      end)

    Enum.find_value(errors, changeset, fn {_field, {_message, meta}} ->
      Map.get(reasons, to_string(Keyword.get(meta, :constraint_name)))
    end)
  end
end
