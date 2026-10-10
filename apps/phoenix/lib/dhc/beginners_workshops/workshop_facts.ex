defmodule Dhc.BeginnersWorkshops.WorkshopFacts do
  @moduledoc """
  The facts about a Beginners' Workshop that live outside its own row: paid
  seats, live Seat Holds, Batches, pause state and Staff.

  The boundary reads them under the workshop lock and the read models read
  them without one, through this one module, so an advisory stage or seat
  meter can be stale but never computed differently from the rule the
  boundary applies.

  ALE-380 fills in the Batch facts (`batches_sent`, `latest_window_end`),
  pausing (`batches_paused`, read from the workshop row), Intakes (`intakes`,
  for the fee lock) and paid Intakes (`paid`). ALE-379 adds **Staff**
  (`staff`, and `coach_assigned` derived from it). ALE-381 adds **Seat
  Holds** (`holds`): payment rows in `open`. Seats taken = `paid` + `holds`;
  `releasing` rows do not count, because their Intake is already closed.
  """

  import Ecto.Query

  alias Dhc.BeginnersWorkshops.{Batch, BeginnersWorkshop, Intake, IntakePayment, StaffAssignment}
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile

  @typedoc "One Staff member as the dashboard names them."
  @type staff_member :: %{principal_id: binary(), name: String.t()}

  @type staff :: %{coach: staff_member() | nil, assistants: [staff_member()]}

  @type t :: %{
          paid: non_neg_integer(),
          holds: non_neg_integer(),
          batches_sent: non_neg_integer(),
          latest_window_end: DateTime.t() | nil,
          batches_paused: boolean(),
          intakes: non_neg_integer(),
          coach_assigned: boolean(),
          staff: staff()
        }

  @no_staff %{coach: nil, assistants: []}

  @empty %{
    paid: 0,
    holds: 0,
    batches_sent: 0,
    latest_window_end: nil,
    batches_paused: false,
    intakes: 0,
    coach_assigned: false,
    staff: @no_staff
  }

  @doc "The facts for each workshop id."
  @spec load([binary()]) :: %{binary() => t()}
  def load([]), do: %{}

  def load(workshop_ids) when is_list(workshop_ids) do
    staff = load_staff(workshop_ids)

    paused =
      from(w in BeginnersWorkshop, where: w.id in ^workshop_ids, select: {w.id, w.batches_paused})
      |> Repo.all()
      |> Map.new()

    batches =
      from(b in Batch,
        where: b.workshop_id in ^workshop_ids,
        group_by: b.workshop_id,
        select: {b.workshop_id, %{sent: count(b.id), latest_window_end: max(b.window_ends_at)}}
      )
      |> Repo.all()
      |> Map.new()

    intakes =
      from(i in Intake,
        where: i.workshop_id in ^workshop_ids,
        group_by: i.workshop_id,
        select: {i.workshop_id, %{all: count(i.id), paid: filter(count(i.id), i.state == "paid")}}
      )
      |> Repo.all()
      |> Map.new()

    holds =
      from(p in IntakePayment,
        where: p.workshop_id in ^workshop_ids and p.status == "open",
        group_by: p.workshop_id,
        select: {p.workshop_id, count(p.id)}
      )
      |> Repo.all()
      |> Map.new()

    Map.new(workshop_ids, fn id ->
      batch = Map.get(batches, id, %{sent: 0, latest_window_end: nil})
      intake = Map.get(intakes, id, %{all: 0, paid: 0})

      facts = %{
        @empty
        | paid: intake.paid,
          holds: Map.get(holds, id, 0),
          intakes: intake.all,
          batches_sent: batch.sent,
          latest_window_end: batch.latest_window_end,
          batches_paused: Map.get(paused, id, false)
      }

      {id, with_staff(facts, Map.get(staff, id, @no_staff))}
    end)
  end

  @doc "The facts of a workshop with nothing attached to it."
  @spec empty() :: t()
  def empty, do: @empty

  @doc "Every principal on the workshop's Staff (the assignment-scope resource)."
  @spec assigned_principal_ids(t()) :: [binary()]
  def assigned_principal_ids(%{staff: %{coach: coach, assistants: assistants}}),
    do: Enum.map(List.wrap(coach) ++ assistants, & &1.principal_id)

  # ── Staff ───────────────────────────────────────────────────────

  defp with_staff(facts, staff), do: %{facts | staff: staff, coach_assigned: staff.coach != nil}

  # Assistants are listed by name, so the list reads the same everywhere. A
  # Staff member without a profile (never expected) is still listed.
  defp load_staff(workshop_ids) do
    from(s in StaffAssignment,
      left_join: p in UserProfile,
      on: p.principal_id == s.principal_id,
      where: s.workshop_id in ^workshop_ids,
      order_by: [asc: p.first_name, asc: p.last_name, asc: s.principal_id],
      select: %{
        workshop_id: s.workshop_id,
        role: s.role,
        principal_id: s.principal_id,
        first_name: p.first_name,
        last_name: p.last_name
      }
    )
    |> Repo.all()
    |> Enum.group_by(& &1.workshop_id)
    |> Map.new(fn {id, rows} -> {id, staff_of(rows)} end)
  end

  defp staff_of(rows) do
    {coaches, assistants} = Enum.split_with(rows, &(&1.role == "coach"))

    %{
      coach: coaches |> List.first() |> then(&(&1 && member(&1))),
      assistants: Enum.map(assistants, &member/1)
    }
  end

  defp member(row),
    do: %{principal_id: row.principal_id, name: display_name(row.first_name, row.last_name)}

  @doc false
  @spec display_name(String.t() | nil, String.t() | nil) :: String.t()
  def display_name(first, last) do
    case [first, last] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ") do
      "" -> "Unnamed member"
      name -> name
    end
  end
end
