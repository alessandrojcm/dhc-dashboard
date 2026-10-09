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
      Intake               contacted → paid
      payment (Seat Hold)  open → paid | releasing | released | policy_failed
                           releasing → released | paid

  The workshop end states are terminal. Intakes are created `contacted`
  (ALE-380); ALE-381 adds `contacted → paid` and the payment rows. Later
  Intake moves, refunds and Carried Fees join the table with the tickets
  that create them.

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
      `policy_failed` and leaves the Intake `contacted` (the automatic
      refund arrives with the refunds ticket). Otherwise the row becomes
      `paid`, an open Intake becomes `paid` (`paid_via: stripe`) and "Place
      confirmed – paid" is queued with its log row in the same transaction.
    * `release_payment` (`:stripe`) runs on `checkout.session.expired`.
    * `reap_holds` (`:system`, a sweep pass) asks Stripe to expire every
      session whose hold ran out and settles the row from Stripe's answer
      (expired → released, completed → paid). Our clock alone never frees a
      seat.

  A payment-started command peeks the row by session id without a lock,
  then locks Beginners' Workshop → Intake → payment from the top down and
  decides on the re-read row. The row's workshop and Intake never change,
  so the peek never goes stale.
  """

  import Ecto.Query

  alias Dhc.Auth
  alias Dhc.Auth.{Capabilities, Principal}

  alias Dhc.BeginnersWorkshops.{
    Batch,
    BatchProposal,
    BeginnersWorkshop,
    Clock,
    Intake,
    IntakeCheckout,
    IntakeEmailLog,
    IntakeEmails,
    IntakeLink,
    IntakePayment,
    StaffAssignment,
    WorkshopFacts,
    WorkshopPolicy,
    WorkshopProjection
  }

  alias Dhc.BeginnersWorkshops.IntakeEmails.Values
  alias Dhc.ClubCalendar
  alias Dhc.Notifications
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

  Staff attributes (`set_staff`, and optional on a schedule) are
  `coach_principal_id` (`nil` for no coach) and `assistant_principal_ids`
  (a list). `set_staff` replaces the whole Staff list.
  """
  @type command ::
          {:schedule_workshop, [map()]}
          | {:update_workshop, workshop_id :: binary(), map()}
          | {:pause_batches, workshop_id :: binary()}
          | {:resume_batches, workshop_id :: binary()}
          | {:send_due_batch, workshop_id :: binary()}
          | {:set_staff, workshop_id :: binary(), map()}
          | :start_payment
          | {:complete_payment, session_id_or_object :: String.t() | map()}
          | {:release_payment, session_id_or_object :: String.t() | map()}
          | :reap_holds
          | {:fast_track, workshop_id :: binary(), fast_track_person()}

  @typedoc """
  Who `fast_track` places: an existing Waitlist entry by id, or a new
  person's registration details (the public registration body, string keys).
  """
  @type fast_track_person :: {:waitlist_entry, binary()} | {:new_person, map()}

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
          | Ecto.Changeset.t()
          | {:workshop, non_neg_integer(), atom() | Ecto.Changeset.t()}

  # Command → the capability a staff actor needs. Every staff command is
  # listed; `authorize/2` refuses anything else before a read.
  @staff_capabilities %{
    schedule_workshop: :"beginners.workshops.manage",
    update_workshop: :"beginners.workshops.manage",
    pause_batches: :"beginners.workshops.manage",
    resume_batches: :"beginners.workshops.manage",
    set_staff: :"beginners.workshops.manage",
    fast_track: :"beginners.workshops.manage"
  }

  # Commands only the `:system` actor (time-driven passes) may run.
  @system_commands [:send_due_batch, :reap_holds]

  # The person's Intake-page commands (`{:intake_link, token}`).
  @intake_link_commands [:start_payment]

  # Stripe-driven commands (webhooks and the success return).
  @stripe_commands [:complete_payment, :release_payment]

  # How many expired holds one `reap_holds` pass settles; the next sweep
  # takes the rest.
  @reap_batch 100

  # The coordinator-alert recipients (ALE-380).
  @alerts_capability :"beginners.workshops.alerts.receive"

  # A Batch pass that loses a proposed person to a concurrent command retries
  # from a fresh proposal this many times before giving up until the next
  # sweep.
  @batch_attempts 3

  @lock_levels [:workshop, :waitlist_entry, :intake, :carried_fee, :payment, :refund]

  @transitions %{
    workshop: %{"scheduled" => ~w(finalised cancelled)},
    intake: %{"contacted" => ~w(paid)},
    payment: %{
      "open" => ~w(paid releasing released policy_failed),
      "releasing" => ~w(released paid)
    }
  }

  # The status field of each entity in the transition table.
  @status_fields %{workshop: :status, intake: :state, payment: :status}

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
    ]
  }

  @check_constraints %{
    BeginnersWorkshop => [
      {:status, "beginners_workshops_status_check"},
      {:venue, "beginners_workshops_venue_check"},
      {:capacity, "beginners_workshops_capacity_check"},
      {:fee_cents, "beginners_workshops_fee_check"},
      {:payment_window_days, "beginners_workshops_payment_window_check"}
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
      {:state, "beginners_workshop_intakes_paid_check"}
    ],
    IntakePayment => [
      {:status, "beginners_workshop_intake_payments_status_check"},
      {:amount_cents, "beginners_workshop_intake_payments_amount_check"},
      {:currency, "beginners_workshop_intake_payments_currency_check"}
    ],
    StaffAssignment => [{:role, "beginners_workshop_staff_role_check"}]
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

  defp authorize(actor, command) do
    name = command_name(command)

    case Map.fetch(@staff_capabilities, name) do
      {:ok, capability} -> authorize_staff(actor, capability)
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

  defp authorize_staff({:staff, principal_id}, capability) when is_binary(principal_id) do
    with {:ok, id} <- Ecto.UUID.cast(principal_id),
         {:ok, projection} <- Auth.load_session_principal(%Principal{id: id}),
         :ok <- Capabilities.authorize(projection, capability) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  defp authorize_staff(_actor, _capability), do: {:error, :forbidden}

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

  defp run(:stripe, {:complete_payment, session}, clock) do
    with {:ok, session} <- session_object(session), do: complete_payment(session, clock)
  end

  defp run(:stripe, {:release_payment, session}, clock) do
    with {:ok, session} <- session_object(session), do: release_payment(session, clock)
  end

  defp run(:system, :reap_holds, clock), do: reap_holds(clock)

  defp run({:staff, _principal_id}, {:fast_track, workshop_id, person}, clock) do
    with {:ok, workshop_id} <- cast_id(workshop_id),
         {:ok, person} <- fast_track_person(person) do
      transact(fn ->
        with_locked(
          %{
            workshop: required(from(w in BeginnersWorkshop, where: w.id == ^workshop_id)),
            waitlist_entry: fast_track_entry_query(person)
          },
          &fast_track_locked(&1, person, clock)
        )
      end)
    end
  end

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

  defp fast_track_locked(%{workshop: workshop, waitlist_entry: entry}, person, clock) do
    reading = Clock.read(clock)

    with :ok <- still_scheduled(workshop),
         :ok <- payment_open(workshop, reading),
         {:ok, entry, placed} <- fast_track_entry(person, entry, reading),
         {:ok, first_name} <- contactable(entry),
         {:ok, intake} <-
           contact(workshop, :fast_track, entry, first_name, workshop.payment_cutoff, reading) do
      {:ok, fast_track_view(intake, placed)}
    end
  end

  # The Carried Fee holder exception after the cutoff joins this rule with
  # the defer-and-confirm ticket.
  defp payment_open(workshop, reading) do
    if WorkshopPolicy.payment_open?(workshop, reading), do: :ok, else: {:error, :after_cutoff}
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
         {:ok, _job} <-
           IntakeEmails.queue(
             "contact_pay",
             entry,
             contact_values(workshop, window_end, first_name),
             button_url: IntakeLink.url(token)
           ),
         {:ok, _log} <-
           %{
             intake_id: intake.id,
             email_type: "contact_pay",
             occasion: "contact",
             queued_at: reading.now
           }
           |> IntakeEmailLog.changeset()
           |> persist() do
      {:ok, intake}
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
  defp take_hold(%{workshop: workshop, intake: intake, payment: open}, clock) do
    reading = Clock.read(clock)

    cond do
      intake.state == "paid" -> {:error, :already_paid}
      intake.state != "contacted" or workshop.status != "scheduled" -> {:error, :intake_closed}
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
          else: record_policy_failure(payment, details, reading)

      {_status, _not_paid} ->
        {:ok, %{outcome: :not_paid}}
    end
  end

  defp record_policy_failure(payment, details, reading) do
    changeset =
      Ecto.Changeset.change(payment,
        status: "policy_failed",
        policy_failed_at: reading.now,
        amount_received_cents: details.amount,
        currency_received: details.currency,
        stripe_payment_intent_id: details.payment_intent
      )

    with {:ok, _payment} <- transition(:payment, payment, changeset),
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

    with {:ok, _payment} <- transition(:payment, payment, changeset) do
      if was_open? and intake.state == "contacted",
        do: pay_intake(intake, workshop, reading),
        # A completion for a hold whose Intake already closed: the payment is
        # recorded; the automatic refund arrives with the refunds ticket.
        else: {:ok, %{outcome: :paid_after_close}}
    end
  end

  defp pay_intake(intake, workshop, reading) do
    with {:ok, intake} <-
           transition(:intake, intake, Intake.paid_changeset(intake, "stripe", reading.now)),
         :ok <- queue_place_confirmed(intake, workshop, reading) do
      {:ok, %{outcome: :paid}}
    end
  end

  defp queue_place_confirmed(%Intake{waitlist_id: nil}, _workshop, _reading), do: :ok

  defp queue_place_confirmed(intake, workshop, reading) do
    entry = Repo.get!(WaitlistEntry, intake.waitlist_id)

    first_name =
      Repo.one(
        from(p in UserProfile,
          where: p.waitlist_id == ^intake.waitlist_id,
          limit: 1,
          select: p.first_name
        )
      ) || ""

    with {:ok, _job} <-
           IntakeEmails.queue(
             "place_confirmed_paid",
             entry,
             %{
               "firstName" => first_name,
               "date" => Values.date(workshop.date),
               "startTime" => Values.start_time(workshop.start_time),
               "venue" => workshop.venue,
               "fee" => Values.money(workshop.fee_cents)
             },
             button_url: IntakeLink.url(IntakeLink.token(intake.id, intake.link_generation))
           ),
         {:ok, _log} <-
           %{
             intake_id: intake.id,
             email_type: "place_confirmed_paid",
             occasion: "place_confirmed",
             queued_at: reading.now
           }
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
    |> Enum.reduce_while({:ok, []}, fn {event, row}, {:ok, acc} ->
      case Notifications.create_keyed_in_transaction(
             row.principal_id,
             "beginners-workshop-staff:#{row.id}:#{event}",
             staff_message(event, row.role, workshop)
           ) do
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
