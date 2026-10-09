defmodule Dhc.BeginnersWorkshops.Commands do
  @moduledoc """
  ALE-378 (ADR 0029 and its amendment): the one implementation of every
  Beginners' Workshop write. `Dhc.BeginnersWorkshops.execute/3` delegates
  here; nothing else in the context opens a write transaction. Staff
  commands, the person's Intake-page commands, Stripe-driven commands and
  time-driven passes all arrive as a `command` with an `actor`. The
  Stripe-facing Intake payment logic (ALE-381) will be an internal module
  reached only through this boundary.

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
  change. ALE-378 has the workshop lifecycle only:

      Beginners' Workshop  scheduled → finalised | cancelled

  Both end states are terminal. Intake, payment, refund and Carried Fee
  rows join the table with the tickets that create them.

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

  No command here sends email.

  ## Staff (ALE-379)

  `beginners_workshop_staff` rows are written only under the Beginners'
  Workshop lock (by `set_staff`, and `schedule_workshop` with optional
  Staff), so they need no lock level of their own. A Staff change notifies
  the people added and removed with keyed Notifications created inside the
  transaction (`Dhc.Notifications.create_keyed_in_transaction/3`) and
  signalled only after it commits.
  """

  import Ecto.Query

  alias Dhc.Auth
  alias Dhc.Auth.{Capabilities, Principal}

  alias Dhc.BeginnersWorkshops.{
    BeginnersWorkshop,
    Clock,
    StaffAssignment,
    WorkshopFacts,
    WorkshopPolicy,
    WorkshopProjection
  }

  alias Dhc.ClubCalendar
  alias Dhc.Notifications
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

  Staff attributes (`set_staff`, and optional on a schedule) are
  `coach_principal_id` (`nil` for no coach) and `assistant_principal_ids`
  (a list). `set_staff` replaces the whole Staff list.
  """
  @type command ::
          {:schedule_workshop, [map()]}
          | {:update_workshop, workshop_id :: binary(), map()}
          | {:set_staff, workshop_id :: binary(), map()}

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
          | :after_finalisation
          | :already_cancelled
          | :invalid_staff
          | :not_a_coach
          | :not_a_member
          | :staff_conflict
          | Ecto.Changeset.t()
          | {:workshop, non_neg_integer(), atom() | Ecto.Changeset.t()}

  # Command → the capability a staff actor needs. Every staff command is
  # listed; `authorize/2` refuses anything else before a read.
  @staff_capabilities %{
    schedule_workshop: :"beginners.workshops.manage",
    update_workshop: :"beginners.workshops.manage",
    set_staff: :"beginners.workshops.manage"
  }

  @lock_levels [:workshop, :waitlist_entry, :intake, :carried_fee, :payment, :refund]

  @transitions %{
    workshop: %{"scheduled" => ~w(finalised cancelled)}
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

  # Unique and check constraints, as the migrations named them, and what each
  # becomes. Unique constraints become a domain reason; check constraints
  # become a field error on the changeset (the changesets already enforce the
  # same shape, so these are the backstop for writers outside the seam).
  @unique_constraints %{
    BeginnersWorkshop => [],
    # Staff rows are written under the workshop lock, so these are backstops.
    StaffAssignment => [
      {:principal_id, "beginners_workshop_staff_workshop_principal_unique", :staff_conflict},
      {:workshop_id, "beginners_workshop_staff_one_coach", :staff_conflict}
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
    case Map.fetch(@staff_capabilities, command_name(command)) do
      {:ok, capability} -> authorize_staff(actor, capability)
      :error -> {:error, :unknown_command}
    end
  end

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
         :ok <- contact_from_change_allowed(input, facts),
         cutoff = resolve_cutoff(next, workshop),
         :ok <- cutoff_before_start(cutoff, WorkshopPolicy.starts_at(workshop)),
         :ok <- contact_from_still_valid(next.contact_from, cutoff, facts),
         # Capacity may rise at any time before finalisation. Lowering it
         # below the seats taken is refused once Seat Holds exist (ALE-381);
         # the fee locks once an Intake exists (ALE-380). A new window
         # length applies to Batches sent after it (ALE-380).
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

  # ── set_staff ───────────────────────────────────────────────────

  defp set_staff_locked(%{workshop: workshop}, staff, actor_id, clock) do
    with :ok <- staff_editable(workshop),
         {:ok, created} <- apply_staff(workshop, current_staff(workshop), staff, actor_id) do
      {:ok, {WorkshopProjection.view(workshop, facts_for(workshop), Clock.read(clock)), created}}
    end
  end

  # Staff can change at any time before Attendance Finalisation (story 17);
  # the Staff list of a finalised workshop is its permanent record.
  defp staff_editable(%BeginnersWorkshop{status: "scheduled"}), do: :ok
  defp staff_editable(%BeginnersWorkshop{status: "finalised"}), do: {:error, :after_finalisation}
  defp staff_editable(%BeginnersWorkshop{status: "cancelled"}), do: {:error, :already_cancelled}

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
