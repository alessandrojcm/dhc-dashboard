defmodule Dhc.BeginnersWorkshops.Commands do
  @moduledoc """
  ALE-378 (ADR 0029 and its amendment): the one implementation of every
  Beginners' Workshop write. `Dhc.BeginnersWorkshops.execute/3` delegates
  here; nothing else in the context opens a write transaction (the one
  `Repo.transaction` is `Commands.Protocol.transact/1`). Staff
  commands, the person's Intake-page commands, Stripe-driven commands and
  time-driven passes all arrive as a `command` with an `actor`. The
  Stripe-facing Intake payment logic (ALE-381) is the internal
  `Dhc.BeginnersWorkshops.IntakeCheckout`, reached only through this
  boundary.

  ## The protocol

  Every command body runs inside the protocol core,
  `Dhc.BeginnersWorkshops.Commands.Protocol` (ADR 0029, second amendment):
  `transact/1` around `with_locked/2`, the clock read under the lock, and
  every write through `persist/1` (`transition/3` for a status change).
  Its moduledoc holds the lock order, the transition table, the constraint
  translation and the signal-after-commit rule. Reach lets only `Commands`
  and `Commands.*` call it.

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
  Intake queues its Contact email through `IntakeEmails.deliver/5`, which
  writes the Intake Email ledger row in the same transaction, and the coordinator-alert
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
      `IntakeEmails.Occasion.pre_workshop/1`), so anyone who had it gets it
      again at the new cutoff through the same Payment Cutoff pass;
    * every Staff member (the actor included) gets a keyed Notification
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
    * every Staff member (the actor included) gets the keyed Notification
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
  is the Batch one, with `{{windowEnd}}` rendering its Payment Window
  (`WorkshopPolicy.payment_window_end/3`: the Payment Cutoff, or the workshop
  start for a Carried Fee holder placed after it). The person pays the
  workshop fee like everyone else.

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
  (the same `follow_up_email/3`); before then the sweep sends it. Other
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

  ## Settlement (ALE-404)

  What every closing above does to the person — standing, Seat Hold,
  Carried Fee, refund, notice — is one row of
  `Dhc.BeginnersWorkshops.Commands.Settlement`, keyed by cause and ending
  and run inside the command's `with_locked/2`. A command decides whether
  it may run (`IntakePolicy`, `CarriedFeePolicy`, `WorkshopPolicy`), names
  the row, and writes its own history row; a new ending is a new row there.

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

  Failed refunds ignore later events. A Stripe-completed refund can still
  fail asynchronously; manual completions and stale events remain settled. When a refund
  fails, the coordinator-alert holders get a keyed Notification
  (`beginners-workshop-refund:<id>:failed`, signalled after commit). Neither
  a failed refund nor a manual refund record emails the person.
  """

  import Ecto.Query

  alias Dhc.Auth
  alias Dhc.Auth.{Capabilities, Principal}
  alias Dhc.BeginnersWorkshops.{Clock, IntakePolicy, StaffAssignment}

  alias Dhc.BeginnersWorkshops.Commands.{
    Attendance,
    Batches,
    IntakeCommands,
    Payments,
    People,
    Protocol,
    Refunds,
    Schedule,
    Staff
  }

  alias Dhc.Repo

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

  # Command → the family module that runs it (ALE-405). A console Intake
  # command (`{command, workshop_id, intake_id, attrs}`, `IntakePolicy`) is
  # routed by its shape first: `withdraw` and `refund_carried_fee` are also
  # the Waitlist tab's `{command, waitlist_id, attrs}` (`People`), and
  # `confirm` is also the person's own `:confirm` (`Payments`).
  @families %{
    schedule_workshop: Schedule,
    update_workshop: Schedule,
    reschedule_workshop: Schedule,
    cancel_workshop: Schedule,
    pause_batches: Schedule,
    resume_batches: Schedule,
    send_due_batch: Batches,
    fast_track: Batches,
    start_payment: Payments,
    confirm: Payments,
    complete_payment: Payments,
    release_payment: Payments,
    reap_holds: Payments,
    submit_refund: Refunds,
    apply_refund_event: Refunds,
    reconcile: Refunds,
    retry_refund: Refunds,
    record_manual_refund: Refunds,
    forfeit_carried_fee: Refunds,
    withdraw: People,
    refund_carried_fee: People,
    link_carried_fee_payment: People,
    delete_person: People,
    purge_retention: People,
    import_carried_fee: People,
    check_in: Attendance,
    undo_check_in: Attendance,
    pass_payment_cutoff: Attendance,
    finish_workshop: Attendance,
    finalise_attendance: Attendance,
    send_follow_ups: Attendance,
    invite: Attendance,
    set_staff: Staff
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
  defdelegate transitions, to: Protocol

  @doc "Whether `from → to` is a legal status change for `entity`."
  @spec transition_allowed?(atom(), String.t(), String.t()) :: boolean()
  defdelegate transition_allowed?(entity, from, to), to: Protocol

  @doc "The lock levels, in the only order a command may take them."
  @spec lock_levels() :: [atom()]
  defdelegate lock_levels, to: Protocol

  @doc false
  # Constraint names `persist/1` translates; a test checks each one exists.
  @spec declared_constraints() :: [String.t()]
  defdelegate declared_constraints, to: Protocol

  @doc false
  # ALE-402 parity seam (`Commands.IntakeCommands`).
  @spec locked_intake_facts(binary(), binary(), Clock.t()) ::
          {:ok, IntakePolicy.t()} | {:error, term()}
  defdelegate locked_intake_facts(workshop_id, intake_id, clock), to: IntakeCommands

  @doc false
  # ALE-402 parity seam (`Commands.People`).
  @spec locked_carried_fee_facts(binary(), Clock.t()) ::
          {:ok, Dhc.BeginnersWorkshops.CarriedFeePolicy.t()} | {:error, term()}
  defdelegate locked_carried_fee_facts(waitlist_id, clock), to: People

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
  # Public only so `Commands.Attendance` re-checks it under the workshop
  # lock (check-in, Finish); Reach keeps it inside the `Commands` namespace.
  @doc false
  @spec authorize_assigned(binary(), atom(), term()) :: :ok | {:error, :forbidden | :not_found}
  def authorize_assigned(principal_id, capability, workshop_id) do
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

  # ── Routing ─────────────────────────────────────────────────────

  defp run(actor, command, clock) do
    case family(command) do
      nil -> {:error, :unknown_command}
      family -> family.run(actor, command, clock)
    end
  end

  defp family({command, _workshop_id, _intake_id, _attrs}) when command in @intake_commands,
    do: IntakeCommands

  defp family(command), do: Map.get(@families, command_name(command))
end
