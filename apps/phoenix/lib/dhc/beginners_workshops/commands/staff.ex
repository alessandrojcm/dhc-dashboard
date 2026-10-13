defmodule Dhc.BeginnersWorkshops.Commands.Staff do
  @moduledoc """
  The Staff of a Beginners' Workshop (ALE-379, ALE-405): `set_staff`
  (`beginners.workshops.manage`) and every Staff Notification.
  `Dhc.BeginnersWorkshops.Commands` authorizes the actor and routes here.

  `beginners_workshop_staff` rows are written only under the Beginners'
  Workshop lock (by `set_staff`, and `schedule_workshop` with optional
  Staff), so they need no lock level of their own. A Staff change notifies
  the people added and removed with keyed Notifications created inside the
  transaction (`Dhc.Notifications.create_keyed_in_transaction/3`) and
  signalled only after it commits.

  `set_staff` replaces the whole Staff list (`coach_principal_id`,
  `assistant_principal_ids`) at any time before Attendance Finalisation; a
  new coach must hold `beginners.workshops.lead` (`:not_a_coach`) and a new
  assistant be an active Member (`:not_a_member`).

  ## Used by other families

    * `staff_input/1` and `apply_staff/4` — `Commands.Schedule`
      (`schedule_workshop`'s optional Staff);
    * `notify_each_staff/3` — `Commands.Schedule` (the reschedule and
      cancel Notifications, worded by `Commands.NotificationCopy`).

  A family never calls another family's private functions (ALE-405).
  """

  import Ecto.Query

  import Dhc.BeginnersWorkshops.Commands.Protocol,
    only: [
      create_keyed: 1,
      persist: 1,
      required: 1,
      signal_after_commit: 1,
      transact: 1,
      with_locked: 2
    ]

  import Dhc.BeginnersWorkshops.Commands.Input,
    only: [cast_id: 1, fetch_attr: 2]

  import Dhc.BeginnersWorkshops.Commands.WorkshopRules,
    only: [facts_for: 1, still_scheduled: 1]

  alias Dhc.Auth.Capabilities

  alias Dhc.BeginnersWorkshops.{
    BeginnersWorkshop,
    Clock,
    StaffAssignment,
    WorkshopProjection
  }

  alias Dhc.BeginnersWorkshops.Commands
  alias Dhc.BeginnersWorkshops.Commands.NotificationCopy

  alias Dhc.Repo

  @doc false
  @spec run(Commands.actor(), Commands.command(), Clock.t()) ::
          {:ok, term()} | {:error, Commands.error()}
  def run({:staff, principal_id}, {:set_staff, workshop_id, attrs}, clock) when is_map(attrs) do
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

  def run(_actor, _command, _clock), do: {:error, :unknown_command}

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
  @doc false
  def staff_input(attrs) do
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
  @doc false
  def apply_staff(workshop, current, staff, actor_id) do
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
        Enum.map(inserted, &{:assigned, &1}) ++ Enum.map(removed, &{:unassigned, &1})
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
  # retried command never twice. Everyone added or removed is told, the
  # person making the change included (spec: "to that staff member").
  defp notify_staff(workshop, events) do
    events
    |> Enum.map(fn {event, row} ->
      {row.principal_id, "beginners-workshop-staff:#{row.id}:#{event}",
       staff_message(event, row.role, workshop)}
    end)
    |> create_keyed()
  end

  defp staff_message(:assigned, role, workshop),
    do: NotificationCopy.staff_assigned(role, workshop)

  defp staff_message(:unassigned, _role, workshop),
    do: NotificationCopy.staff_unassigned(workshop)

  # One keyed Notification to each person on the workshop's Staff.
  @doc false
  def notify_each_staff(workshop, key, body) do
    workshop
    |> current_staff()
    |> Enum.map(& &1.principal_id)
    |> Enum.uniq()
    |> Enum.map(&{&1, key, body})
    |> create_keyed()
  end
end
