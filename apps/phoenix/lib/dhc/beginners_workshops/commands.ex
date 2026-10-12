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

  import Dhc.BeginnersWorkshops.Commands.Protocol,
    only: [
      persist: 1,
      required: 1,
      signal_after_commit: 1,
      transact: 1,
      transition: 3,
      with_locked: 2
    ]

  import Dhc.BeginnersWorkshops.Commands.Input,
    only: [cast_id: 1, cast_person_id: 1, fetch_attr: 2]

  import Dhc.BeginnersWorkshops.Commands.WorkshopRules,
    only: [facts_for: 1]

  import Dhc.BeginnersWorkshops.Commands.LockSpecs,
    only: [
      entry_query: 1,
      intake_spec: 2,
      live_fee_query: 1,
      locked_intake_fee: 1,
      open_payment: 1,
      paying_payment: 1
    ]

  import Dhc.BeginnersWorkshops.Commands.Facts,
    only: [fee_refund: 1, fee_refunded?: 1, held?: 1, latest_fee: 1, read_locked: 2]

  import Dhc.BeginnersWorkshops.Commands.IntakeHistory,
    only: [command_note: 1, record_intake_event: 5]

  import Dhc.BeginnersWorkshops.Commands.IntakeNotices,
    only: [emailed: 1, place_confirmed: 3]

  import Dhc.BeginnersWorkshops.Commands.CoordinatorAlerts, only: [alert: 2]

  alias Dhc.Auth
  alias Dhc.Auth.{Capabilities, Principal}

  alias Dhc.BeginnersWorkshops.{
    BeginnersWorkshop,
    CarriedFee,
    CarriedFeePolicy,
    Clock,
    Intake,
    IntakeCheckout,
    IntakeEmails,
    IntakeLink,
    IntakePayment,
    IntakePolicy,
    IntakeRefund,
    IntakeRefunds,
    StaffAssignment,
    WorkshopPolicy
  }

  alias Dhc.BeginnersWorkshops.Commands.{
    Attendance,
    Batches,
    Protocol,
    Schedule,
    Settlement,
    Staff
  }

  alias Dhc.BeginnersWorkshops.IntakeEmails.{Occasion, Values}
  alias Dhc.BeginnersWorkshops.Workers.RefundWorker
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist
  alias Dhc.Waitlist.WaitlistEntry

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
  # A payment row whose Checkout Session may still need recording: a live
  # hold, or one releasing because its Intake closed meanwhile.
  @unsessioned_statuses ~w(open releasing)

  @refund_outcomes %{"processing" => :processing, "completed" => :completed, "failed" => :failed}

  # How many refunds and payment rows one `reconcile` pass repairs (each);
  # the next tick takes the rest.
  @reconcile_batch 100

  # A Batch pass that loses a proposed person to a concurrent command retries
  # from a fresh proposal this many times before giving up until the next
  # sweep.
  @batch_attempts 3

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
  @doc false
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

  # ── Commands ────────────────────────────────────────────────────

  # ALE-405: the commands of the families split out so far run there.
  @families %{
    set_staff: Staff,
    schedule_workshop: Schedule,
    update_workshop: Schedule,
    reschedule_workshop: Schedule,
    cancel_workshop: Schedule,
    pause_batches: Schedule,
    resume_batches: Schedule,
    send_due_batch: Batches,
    fast_track: Batches,
    check_in: Attendance,
    undo_check_in: Attendance,
    pass_payment_cutoff: Attendance,
    finish_workshop: Attendance,
    finalise_attendance: Attendance,
    send_follow_ups: Attendance,
    invite: Attendance
  }

  defp run(actor, command, clock)
       when is_tuple(command) and is_map_key(@families, elem(command, 0)),
       do: Map.fetch!(@families, elem(command, 0)).run(actor, command, clock)

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

  # ── start_payment ───────────────────────────────────────────────

  defp start_payment(token, clock) do
    with {:ok, peek} <- peek_intake(token),
         {:ok, row} <- transact(fn -> hold_locked(peek, clock) end) do
      checkout(row, clock)
    end
  end

  # The person's entry is locked too: the hold freezes their email for the
  # Checkout Session, read from the locked row.
  defp hold_locked(peek, clock) do
    peek
    |> intake_spec(fn _locked -> open_payment(peek.intake_id) end)
    |> Map.put(:waitlist_entry, entry_query(peek))
    |> Map.put(:carried_fee, &locked_intake_fee/1)
    |> with_locked(&take_hold(&1, clock))
  end

  # The Intake a link resolves to (unlocked): only its stored hash matches.
  defp peek_intake(token) do
    hash = IntakeLink.hash(token)

    from(i in Intake,
      where: i.link_token_hash == ^hash,
      select: %{intake_id: i.id, workshop_id: i.workshop_id, waitlist_id: i.waitlist_id}
    )
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      peek -> {:ok, peek}
    end
  end

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
      true -> new_hold(workshop, intake, Map.get(locked, :waitlist_entry), reading)
    end
  end

  # Pressing Pay again reuses a live hold; one whose 30 minutes ran out
  # waits for Stripe to end its session.
  defp live_hold(open, reading) do
    if DateTime.compare(open.expires_at, reading.now) == :gt,
      do: {:ok, open},
      else: {:error, :payment_in_progress}
  end

  # The hold freezes every Checkout Session parameter from the locked rows
  # (`IntakeCheckout.hold_params/4`), so a later rotation, email edit or
  # reschedule can never change what a replayed create sends.
  defp new_hold(workshop, intake, entry, reading) do
    cond do
      not WorkshopPolicy.payment_open?(workshop, reading) ->
        {:error, :after_cutoff}

      not WorkshopPolicy.seat_free?(workshop, facts_for(workshop)) ->
        {:error, :full}

      true ->
        workshop
        |> IntakeCheckout.hold_params(intake, entry, WorkshopPolicy.hold_expires_at(reading))
        |> IntakePayment.hold_changeset()
        |> persist()
    end
  end

  # Between transactions: reuse the live hold's session, or create it.
  defp checkout(%IntakePayment{checkout_url: url}, _clock) when is_binary(url),
    do: {:ok, %{checkout_url: url, client_secret: nil, session_id: nil}}

  defp checkout(%IntakePayment{stripe_checkout_session_id: id}, _clock) when is_binary(id) do
    case IntakeCheckout.retrieve(id) do
      {:ok, %{"status" => "open", "client_secret" => secret}} when is_binary(secret) ->
        {:ok, %{checkout_url: nil, client_secret: secret, session_id: id}}

      _other ->
        {:error, :payment_unavailable}
    end
  end

  defp checkout(%IntakePayment{} = row, clock) do
    case create_session(row, clock) do
      {:ok, %{id: id, client_secret: secret}} when is_binary(secret) ->
        {:ok, %{checkout_url: nil, client_secret: secret, session_id: id}}

      {:ok, %{url: url}} when is_binary(url) ->
        {:ok, %{checkout_url: url, client_secret: nil, session_id: nil}}

      {:ok, _no_credentials} ->
        {:error, :payment_unavailable}

      {:error, _reason} ->
        {:error, :payment_unavailable}
    end
  end

  # Creates (or replays) the row's Checkout Session, with exactly the
  # parameters the hold froze, and records it. A session Stripe refused to
  # create cannot exist, so its hold is freed; a refusal that does not prove
  # that (`IntakeCheckout` classes an idempotency conflict as retryable)
  # keeps the hold.
  defp create_session(%IntakePayment{} = row, clock) do
    case IntakeCheckout.create(row) do
      {:ok, session} ->
        record_session(row, session)

      {:error, :rejected} ->
        _ = release_unsessioned(row, clock)
        {:error, :payment_unavailable}

      {:error, :retryable} ->
        {:error, :payment_unavailable}
    end
  end

  # After an authoritative re-read: the session is recorded once; a
  # concurrent press that recorded it first wins (the idempotency key makes
  # it the same session).
  defp record_session(row, session),
    do: transact(fn -> with_locked(payment_spec(row), &record_session_locked(&1, session)) end)

  defp record_session_locked(%{payment: payment}, %{id: session_id, url: url} = session) do
    cond do
      payment.stripe_checkout_session_id == session_id ->
        {:ok, %{session | url: payment.checkout_url}}

      payment.status in @unsessioned_statuses and is_nil(payment.stripe_checkout_session_id) ->
        with {:ok, payment} <-
               payment |> IntakePayment.session_changeset(session_id, url) |> persist(),
             do: {:ok, %{session | url: payment.checkout_url}}

      true ->
        {:error, :concurrent_change}
    end
  end

  defp release_unsessioned(row, clock),
    do: transact(fn -> with_locked(payment_spec(row), &release_unsessioned_locked(&1, clock)) end)

  defp release_unsessioned_locked(%{payment: payment}, clock) do
    if payment.status in @unsessioned_statuses and is_nil(payment.stripe_checkout_session_id),
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
        Ecto.Changeset.change(payment, status: "released", released_at: at, checkout_email: nil)
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

  defp pay_intake(intake, workshop, reading) do
    with {:ok, intake} <-
           transition(:intake, intake, Intake.paid_changeset(intake, "stripe", reading.now)),
         :ok <- place_confirmed(intake, workshop, reading) do
      {:ok, %{outcome: :paid}}
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
  # ended stays open (and its seat taken) until the next pass. A releasing
  # hold whose session was never recorded is settled the same way, or a
  # payment made through its session could never be matched and refunded.
  defp reap_holds(clock) do
    now = Clock.read(clock).now

    from(p in IntakePayment,
      where: p.expires_at <= ^now,
      where:
        p.status == "open" or
          (p.status == "releasing" and is_nil(p.stripe_checkout_session_id)),
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
    case create_session(row, clock) do
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
        with :ok <-
               emailed(
                 IntakeEmails.deliver(
                   {:intake, intake, workshop},
                   "payment_refunded",
                   Occasion.payment_refunded(refund.payment_id),
                   reading,
                   refund: refund
                 )
               ),
             do: {:ok, refund}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The full amount originally paid, against the original payment, and its
  # submission job — the one way a refund row is requested. The source is
  # a payment row (what it took, against its PaymentIntent), or (ALE-389) a
  # Carried Fee, `{:carried_fee, fee, payment, intake}`: what the fee's
  # original payment took — its payment row (`payment`, locked by the
  # caller) or, for an imported fee, the Stripe payment staff linked —
  # recorded against `intake`, the Intake the refund is about (else the
  # original payment's own Intake, else none). Public only so
  # `Commands.Settlement` writes its refunds here too; Reach keeps it inside
  # the `Commands` namespace.
  @doc false
  @spec insert_refund(
          IntakePayment.t()
          | {:carried_fee, CarriedFee.t(), IntakePayment.t() | nil, Intake.t() | nil},
          String.t(),
          binary() | nil,
          Clock.reading()
        ) :: {:ok, IntakeRefund.t() | nil} | {:error, term()}
  def insert_refund(%IntakePayment{} = payment, reason, requested_by, reading) do
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

  def insert_refund({:carried_fee, %CarriedFee{} = fee, payment, intake}, reason, by, reading) do
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
      refund.stripe_refund_id not in [nil, stripe_id] ->
        {:ok, {%{outcome: :not_ours}, []}}

      refund.status == "failed" ->
        {:ok, {%{outcome: :already_settled}, []}}

      refund.status == "completed" and
          not (refund.method == "stripe" and object["status"] == "failed") ->
        {:ok, {%{outcome: :already_settled}, []}}

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
         {:ok, fee} <- hold_fee_again(locked, refund, reading),
         {:ok, created} <- notify_if_failed(refund, fee) do
      {:ok, {%{outcome: Map.fetch!(@refund_outcomes, status)}, created}}
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
         {:ok, fee} <- hold_fee_again(locked, refund, reading),
         {:ok, created} <- notify_if_failed(refund, fee),
         do: {:ok, {%{outcome: :failed}, created}}
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
  # since come to hold another live fee (one per person), or has paid an
  # open Intake through Stripe (a held fee beside a paid seat would be two
  # entitlements), this one stays `refunded`: the money is still owed back,
  # and the failed refund is followed up by Retry or Record manual refund.
  defp hold_fee_again(
         %{carried_fee: %CarriedFee{id: id, status: "refunded"} = fee},
         %IntakeRefund{status: "failed", carried_fee_id: id},
         reading
       ) do
    if other_live_fee?(fee) or paid_by_stripe_since?(fee),
      do: {:ok, fee},
      else:
        transition(:carried_fee, fee, CarriedFee.status_changeset(fee, "held", nil, reading.now))
  end

  defp hold_fee_again(_locked, _refund, _reading), do: {:ok, nil}

  defp other_live_fee?(%CarriedFee{waitlist_id: nil}), do: false

  defp other_live_fee?(%CarriedFee{id: id, waitlist_id: waitlist_id}),
    do: Repo.exists?(from(f in live_fee_query(waitlist_id), where: f.id != ^id))

  defp paid_by_stripe_since?(%CarriedFee{waitlist_id: nil}), do: false

  defp paid_by_stripe_since?(%CarriedFee{waitlist_id: waitlist_id}),
    do:
      Repo.exists?(
        from(i in Intake,
          where: i.waitlist_id == ^waitlist_id and i.state == "paid" and i.paid_via == "stripe"
        )
      )

  # A failed refund is a coordinator's job (story 84): a keyed Notification
  # per refund row, so a retried command never notifies twice.
  # `fee` is what `hold_fee_again/3` left: held again, or still `refunded`
  # (the money is still owed back, so there is nothing to forfeit).
  defp notify_if_failed(%IntakeRefund{status: "failed"} = refund, fee) do
    %{first_name: first_name, date: date} = refund_person(refund)
    workshop = if date, do: " for the Beginners' Workshop on #{Values.date(date)}", else: ""

    follow_up =
      case {refund.carried_fee_id, fee} do
        {nil, _fee} ->
          "Retry it or record a manual refund from the workshop console."

        {_fee_id, %CarriedFee{status: "held"}} ->
          "It was a Carried Fee refund, so the fee is held again: retry it, record a manual " <>
            "refund or forfeit the fee from the workshop console or the Waitlist."

        {_fee_id, %CarriedFee{status: "refunded"}} ->
          "It was a Carried Fee refund and the person has since paid or holds another fee, so " <>
            "the money is still owed back: retry it or record a manual refund from the " <>
            "workshop console or the Waitlist."

        {_fee_id, _fee} ->
          "It was a Carried Fee refund: retry it or record a manual refund from the workshop " <>
            "console or the Waitlist."
      end

    alert(
      "beginners-workshop-refund:#{refund.id}:failed",
      "A refund of #{Values.refund_amount(refund)} to #{first_name || "an anonymised person"}" <>
        "#{workshop} failed. " <> follow_up
    )
  end

  defp notify_if_failed(_refund, _fee), do: {:ok, []}

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

  defp follow_up_locked(
         %{refund: failed, carried_fee: fee} = locked,
         :forfeit,
         _principal_id,
         clock
       ) do
    reading = Clock.read(clock)

    with :ok <- CarriedFeePolicy.check(:forfeit, follow_up_facts(locked, reading)),
         {:ok, fee} <-
           transition(
             :carried_fee,
             fee,
             CarriedFee.status_changeset(fee, "forfeited", nil, reading.now)
           ) do
      {:ok, %{id: fee.id, status: fee.status, refund_id: failed.id}}
    end
  end

  defp follow_up_locked(%{refund: failed, carried_fee: fee} = locked, action, principal_id, clock) do
    reading = Clock.read(clock)

    with :ok <-
           CarriedFeePolicy.check(follow_up_command(action), follow_up_facts(locked, reading)),
         {:ok, refund} <- follow_up_row(action, failed, locked.payment, principal_id, reading),
         {:ok, _fee} <- refund_fee_again(fee, reading) do
      {:ok, refund_view(refund)}
    end
  end

  defp follow_up_command({:manual, _note}), do: :manual
  defp follow_up_command(:retry), do: :retry

  # ALE-389: `CarriedFeePolicy` decides a follow-up from the refund
  # followed up — failed, with no follow-up row and (for a Carried Fee's)
  # still the fee's latest — and the fee it refunds, which must still be
  # owed back.
  defp follow_up_facts(%{refund: refund, carried_fee: fee} = locked, reading) do
    CarriedFeePolicy.facts(
      fee: fee,
      refund: refund && %{status: refund.status, followed_up: followed_up?(refund, fee)},
      entry: Map.get(locked, :waitlist_entry),
      now: reading.now
    )
  end

  # Every refund writer of a payment holds its lock; the follows index is
  # the backstop.
  defp followed_up?(%IntakeRefund{status: "failed", id: id} = refund, fee) do
    Repo.exists?(from(r in IntakeRefund, where: r.follows_refund_id == ^id)) or
      (fee != nil and superseded?(refund))
  end

  defp followed_up?(_not_failed, _fee), do: false

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

  defp intake_command_locked(%{intake: intake} = locked, command, context, clock) do
    reading = Clock.read(clock)
    facts = policy_facts(locked, context, reading)

    case IntakePolicy.check(command, facts) do
      :ok ->
        event_id = Ecto.UUID.generate()
        locked = Map.merge(locked, %{context: context, facts: facts})

        with {:ok, intake} <- act_on_intake(command, locked, event_id, reading),
             {:ok, _event} <- record_intake_event(intake, command, event_id, context, reading) do
          {:ok, intake_command_view(intake, :done)}
        end

      :already_done ->
        {:ok, intake_command_view(intake, :already_done)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # What each closing does to the person is its `Commands.Settlement` row;
  # the command only names it.
  defp act_on_intake(:decline, locked, _event_id, reading),
    do: settle({:decline, :contacted}, hold_rows(locked), reading)

  # A deferral keeps the person's money as a Carried Fee and their place in
  # the queue (story 69).
  defp act_on_intake(:defer, locked, _event_id, reading),
    do: settle({:defer, :paid}, locked, reading)

  # ALE-387: a paid person wants their money back (ALE-389: a
  # Carried-Fee-paid Intake refunds the Carried Fee).
  defp act_on_intake(:cancel_with_refund, %{intake: intake} = locked, _event_id, reading),
    do: settle({:cancel_with_refund, Settlement.paid_by(intake)}, locked, reading)

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
             :ok <- place_confirmed(intake, workshop, reading) do
          {:ok, intake}
        end
    end
  end

  # ALE-387: the person leaves the Waitlist. Money is never handled
  # implicitly: a paid Intake, and (ALE-389) any Carried Fee the person
  # holds, needs the refund-or-forfeit choice, and the person is told which.
  defp act_on_intake(:withdraw, %{intake: %Intake{state: "contacted"}} = locked, _id, reading),
    do: settle({:withdraw, :contacted}, hold_rows(locked), reading)

  defp act_on_intake(
         :withdraw,
         %{intake: %Intake{state: "paid"} = intake} = locked,
         _id,
         reading
       ),
       do: settle({:withdraw, Settlement.paid_by(intake)}, locked, reading)

  # ALE-389: the person's `held` Carried Fee is refunded; nothing else
  # moves (a contacted Intake now asks for payment).
  defp act_on_intake(:refund_carried_fee, locked, _event_id, reading),
    do: settle({:refund_carried_fee, :open_intake}, locked, reading)

  defp act_on_intake(:resend_link, %{workshop: workshop, intake: intake}, event_id, reading) do
    with :ok <-
           emailed(
             IntakeEmails.deliver(
               {:intake, intake, workshop},
               :link,
               Occasion.resend_link(event_id),
               reading
             )
           ),
         do: {:ok, intake}
  end

  defp act_on_intake(:rotate_link, %{workshop: workshop, intake: intake}, event_id, reading) do
    token = IntakeLink.token(intake.id, intake.link_generation + 1)

    with {:ok, intake} <-
           intake |> Intake.rotate_link_changeset(IntakeLink.hash(token)) |> persist(),
         :ok <-
           emailed(
             IntakeEmails.deliver(
               {:intake, intake, workshop},
               :link,
               Occasion.rotate_link(event_id),
               reading
             )
           ) do
      {:ok, intake}
    end
  end

  # ALE-393: fix a door mistake, or turn a no-show into a Deferral.
  defp act_on_intake(:correct_attendance, locked, _event_id, reading) do
    %{waitlist_entry: entry, intake: intake, context: context} = locked
    to = context.options.to

    with :ok <- no_other_open_intake(entry, intake, to),
         {:ok, intake} <- settle({:correct_attendance, to}, locked, reading) do
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

  # An Intake command's Settlement, against its locked rows, with the
  # actor, the refund-or-forfeit choice and the facts that say whether the
  # choice is required.
  defp settle(key, %{context: context, facts: facts} = locked, reading) do
    with {:ok, %{intake: intake}} <-
           Settlement.run(key, locked, reading,
             actor: context.actor,
             choice: Map.get(context.options, :refund),
             facts: facts
           ),
         do: {:ok, intake}
  end

  # `decline` and a contacted `withdraw` lock the Intake's live Seat Hold
  # as its payment.
  defp hold_rows(%{payment: hold} = locked),
    do: %{locked | payment: nil} |> Map.put(:holds, List.wrap(hold))

  # What `IntakePolicy.check/2` reads (`IntakePolicy.facts/1`): the locked
  # Intake and workshop and, for the commands that lock them, the person's
  # standing and live Carried Fee (with its latest refund), whether their
  # latest fee was refunded, and a correction's target (ALE-393).
  defp policy_facts(%{intake: intake} = locked, context, reading) do
    fee = live_fee(Map.get(locked, :carried_fee))

    IntakePolicy.facts(
      intake: intake,
      entry: Map.get(locked, :waitlist_entry),
      carried_fee: fee,
      carried_fee_refund: fee_refund(fee),
      latest_fee_refunded:
        fee == nil and is_binary(intake.waitlist_id) and fee_refunded?(intake.waitlist_id),
      workshop_status: locked.workshop.status,
      correction: Map.get(context.options, :to),
      now: reading.now
    )
  end

  # `correct_attendance` locks the fee that paid the Intake, which is no
  # longer live once it is spent or forfeited.
  defp live_fee(%CarriedFee{status: status} = fee) do
    if status in CarriedFee.live_statuses(), do: fee
  end

  defp live_fee(nil), do: nil

  @doc false
  # ALE-402 parity seam: the facts the boundary decides an Intake command
  # by, from the locked read with the widest Intake lock set (entry and
  # live Carried Fee, as `refund_carried_fee` takes them) and no correction.
  # Nothing is written.
  @spec locked_intake_facts(binary(), binary(), Clock.t()) ::
          {:ok, IntakePolicy.t()} | {:error, term()}
  def locked_intake_facts(workshop_id, intake_id, %Clock{} = clock) do
    with {:ok, workshop_id} <- cast_id(workshop_id),
         {:ok, peek} <- peek_console_intake(workshop_id, intake_id) do
      read_locked(intake_command_spec(:refund_carried_fee, peek), fn locked ->
        policy_facts(locked, %{options: %{}}, Clock.read(clock))
      end)
    end
  end

  @doc false
  # ALE-402 parity seam: the `CarriedFeePolicy` facts of the person's live
  # Carried Fee, else their latest, under the entry → Carried Fee locks the
  # Waitlist tab's commands take. Nothing is written.
  @spec locked_carried_fee_facts(binary(), Clock.t()) ::
          {:ok, CarriedFeePolicy.t()} | {:error, term()}
  def locked_carried_fee_facts(waitlist_id, %Clock{} = clock) do
    with {:ok, waitlist_id} <- cast_person_id(waitlist_id) do
      read_locked(
        %{
          waitlist_entry: from(e in WaitlistEntry, where: e.id == ^waitlist_id),
          carried_fee: live_fee_query(waitlist_id)
        },
        fn %{waitlist_entry: entry, carried_fee: fee} ->
          person_fee_facts(entry, fee || latest_fee(waitlist_id), Clock.read(clock))
        end
      )
    end
  end

  # The person's fee as `CarriedFeePolicy` judges it, with its latest
  # refund, under the person's entry lock.
  defp person_fee_facts(entry, fee, reading),
    do: CarriedFeePolicy.facts(fee: fee, refund: fee_refund(fee), entry: entry, now: reading.now)

  defp intake_command_view(%Intake{} = intake, outcome) do
    intake
    |> Map.take([:id, :workshop_id, :state, :link_generation])
    |> Map.put(:outcome, outcome)
  end

  # ── correct_attendance (ALE-393) ────────────────────────────────

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

  # No open Intake: `IntakePolicy.check(:withdraw, _)` with no Intake
  # (ALE-402) over the standing, under the entry lock, and (ALE-389) the
  # person's live Carried Fee, which needs the refund-or-forfeit choice even
  # when they are already removed. An Intake created since the peek (it
  # takes this lock too) is found here.
  defp withdraw_standing(%{waitlist_entry: nil}, _waitlist_id, _context, _clock),
    do: {:error, :person_not_found}

  defp withdraw_standing(%{waitlist_entry: entry, carried_fee: fee}, waitlist_id, context, clock) do
    reading = Clock.read(clock)
    facts = person_facts(entry, fee, reading)

    cond do
      peek_open_intake(waitlist_id) != nil ->
        {:error, :concurrent_change}

      IntakePolicy.check(:withdraw, facts) == :already_done ->
        {:ok, withdraw_person_view(entry, nil, :already_done)}

      true ->
        with {:ok, _settled} <-
               Settlement.run(
                 {:withdraw, :no_intake},
                 %{waitlist_entry: entry, carried_fee: fee},
                 reading,
                 actor: context.actor,
                 choice: context.options.refund,
                 facts: facts
               ),
             do: {:ok, withdraw_person_view(Repo.reload!(entry), nil, :done)}
    end
  end

  # `IntakePolicy`'s facts of a person with no open Intake: their locked
  # entry and live Carried Fee.
  defp person_facts(entry, fee, reading) do
    IntakePolicy.facts(
      intake: nil,
      entry: entry,
      carried_fee: fee,
      carried_fee_refund: fee_refund(fee),
      latest_fee_refunded: fee == nil and fee_refunded?(entry.id),
      workshop_status: nil,
      correction: nil,
      now: reading.now
    )
  end

  defp withdraw_person_view(entry, intake_view),
    do: withdraw_person_view(entry, intake_view, intake_view.outcome)

  defp withdraw_person_view(%WaitlistEntry{} = entry, intake_view, outcome),
    do: %{waitlist_id: entry.id, status: entry.status, intake: intake_view, outcome: outcome}

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
         {:ok, %{carried_fee: fee}} <-
           Settlement.run(
             {:delete_person, :deleted},
             %{waitlist_entry: entry, carried_fee: fee},
             reading,
             actor: principal_id,
             choice: refund
           ),
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
      with {:ok, %{carried_fee: fee}} <-
             Settlement.run(
               {:purge_retention, :purged},
               %{waitlist_entry: entry, carried_fee: fee},
               reading
             ),
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
      {:ok, fee_command_view(waitlist_id, view, view.outcome)}
    end
  end

  # No open Intake: `CarriedFeePolicy.check(:refund, _)` over the person's
  # live fee, else their latest (already done once it was refunded).
  defp refund_fee_alone(%{waitlist_entry: nil}, waitlist_id, _context, _clock) do
    if peek_open_intake(waitlist_id) == nil,
      do: {:error, :person_not_found},
      else: {:error, :concurrent_change}
  end

  defp refund_fee_alone(%{waitlist_entry: entry, carried_fee: nil}, waitlist_id, _context, clock) do
    case CarriedFeePolicy.check(
           :refund,
           person_fee_facts(entry, latest_fee(waitlist_id), Clock.read(clock))
         ) do
      :already_done -> {:ok, fee_command_view(waitlist_id, nil, :already_done)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp refund_fee_alone(%{waitlist_entry: entry, carried_fee: fee}, waitlist_id, context, clock) do
    reading = Clock.read(clock)

    with true <- peek_open_intake(waitlist_id) == nil || {:error, :concurrent_change},
         :ok <- CarriedFeePolicy.check(:refund, person_fee_facts(entry, fee, reading)),
         {:ok, _settled} <-
           Settlement.run(
             {:refund_carried_fee, :no_intake},
             %{waitlist_entry: entry, carried_fee: fee},
             reading,
             actor: context.actor
           ) do
      {:ok, fee_command_view(waitlist_id, nil, :done)}
    end
  end

  defp fee_command_view(waitlist_id, intake_view, outcome) do
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
      outcome: outcome
    }
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

  # `CarriedFeePolicy.check(:link_payment, _)`; asking again for the
  # PaymentIntent already linked is already done.
  defp linkable(%CarriedFee{} = fee, payment_intent_id) do
    facts = CarriedFeePolicy.facts(fee: fee, refund: fee_refund(fee), entry: nil, now: nil)

    case CarriedFeePolicy.check(:link_payment, facts) do
      :ok ->
        if Repo.exists?(
             from(p in IntakePayment, where: p.stripe_payment_intent_id == ^payment_intent_id)
           ),
           do: {:error, :payment_already_linked},
           else: {:ok, {:link, fee}}

      {:error, :already_linked} when fee.stripe_payment_intent_id == payment_intent_id ->
        {:ok, {:linked, fee}}

      {:error, reason} ->
        {:error, reason}
    end
  end

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
end
