defmodule Dhc.BeginnersWorkshops.WorkshopConsole do
  @moduledoc """
  The coordinator console read model of one Beginners' Workshop (ALE-380):
  no locks, no actor (the route's capability gate is the whole
  authorization) — the `Dhc.Inventory.OperatorLoanQueue` shape.

  It carries:

    * `workshop` — `WorkshopProjection.view/3`, the same row the list and
      every workshop command return (stage, seats, alerts);
    * `batches` — every Batch sent, oldest first;
    * `pause` — whether automatic Batches are paused, and who paused or
      resumed them last, and when;
    * `next_batch` — the **Next Batch** preview: `WorkshopPolicy.next_batch/3`
      (when it goes out, or that it is paused, full or closed), its size as
      capacity − paid, and the live `BatchProposal` — exactly the people
      `send_due_batch` would contact now — with minors badged;
    * `roster` — Intakes grouped by meaning before finalisation: `seated`
      (paid), `asked` (contacted, not paid yet) and `out`; each Intake with
      a live Seat Hold carries when its hold runs out (ALE-381);
    * `attention` — `:nobody_waiting` when a Batch is due with free seats
      but nobody eligible is waiting;
    * `fast_track_open` — whether Fast-track is offered now
      (`WorkshopPolicy.payment_open?/2`, the rule `fast_track` applies).

  Because the preview and the pass share `WorkshopPolicy` and
  `BatchProposal`, a stale console can be out of date but never disagree
  with what the boundary would decide.
  """

  import Ecto.Query

  alias Dhc.BeginnersWorkshops.{
    Batch,
    BatchProposal,
    BeginnersWorkshop,
    Clock,
    Intake,
    IntakePayment,
    WorkshopFacts,
    WorkshopPolicy,
    WorkshopProjection
  }

  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile

  @type t :: %{
          workshop: WorkshopProjection.t(),
          batches: [map()],
          pause: map(),
          next_batch: map(),
          roster: %{seated: [map()], asked: [map()], out: [map()]},
          attention: [:nobody_waiting],
          fast_track_open: boolean()
        }

  @doc "The console of `workshop_id` at the clock's current reading."
  @spec show(binary(), Clock.t()) :: {:ok, t()} | {:error, :not_found}
  def show(workshop_id, %Clock{} = clock) do
    with {:ok, id} <- Ecto.UUID.cast(workshop_id),
         %BeginnersWorkshop{} = workshop <- Repo.get(BeginnersWorkshop, id) do
      facts = Map.fetch!(WorkshopFacts.load([id]), id)
      reading = Clock.read(clock)
      next_batch = next_batch(workshop, facts, reading)

      {:ok,
       %{
         workshop: WorkshopProjection.view(workshop, facts, reading),
         batches: batches(id),
         pause: pause(workshop),
         next_batch: next_batch,
         roster: roster(workshop),
         attention: attention(next_batch),
         fast_track_open: WorkshopPolicy.payment_open?(workshop, reading)
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  defp batches(workshop_id) do
    from(b in Batch,
      where: b.workshop_id == ^workshop_id,
      order_by: [asc: b.number],
      select: map(b, [:number, :size, :sent_at, :window_ends_at])
    )
    |> Repo.all()
  end

  defp pause(workshop) do
    %{
      paused: workshop.batches_paused,
      paused_at: workshop.batches_paused_at,
      paused_by: name_of(workshop.batches_paused_by_principal_id),
      resumed_at: workshop.batches_resumed_at,
      resumed_by: name_of(workshop.batches_resumed_by_principal_id)
    }
  end

  defp next_batch(workshop, facts, reading) do
    timing = WorkshopPolicy.next_batch(workshop, facts, reading)
    size = WorkshopPolicy.batch_size(workshop, facts)

    people =
      if timing in [:full, :closed],
        do: [],
        else: Enum.map(BatchProposal.people(size), &person(&1, workshop))

    {status, goes_out_at} =
      case timing do
        {:at, at} -> {:scheduled, at}
        other -> {other, nil}
      end

    %{
      status: status,
      goes_out_at: goes_out_at,
      number: facts.batches_sent + 1,
      size: size,
      capacity: workshop.capacity,
      paid: facts.paid,
      people: people
    }
  end

  defp person(row, workshop) do
    %{
      first_name: row.first_name,
      last_name: row.last_name,
      minor: WorkshopPolicy.minor?(row.date_of_birth, workshop.date),
      queue_date: row.queue_date
    }
  end

  defp roster(workshop) do
    rows =
      from(i in Intake,
        left_join: b in Batch,
        on: b.id == i.batch_id,
        left_join: p in UserProfile,
        on: p.waitlist_id == i.waitlist_id and not is_nil(i.waitlist_id),
        left_join: h in IntakePayment,
        on: h.intake_id == i.id and h.status == "open",
        where: i.workshop_id == ^workshop.id,
        order_by: [asc: i.queue_date, asc: i.id],
        select: %{
          id: i.id,
          state: i.state,
          origin: i.origin,
          batch_number: b.number,
          queue_date: i.queue_date,
          contacted_at: i.contacted_at,
          hold_expires_at: h.expires_at,
          first_name: p.first_name,
          last_name: p.last_name,
          date_of_birth: p.date_of_birth
        }
      )
      |> Repo.all()
      |> Enum.map(fn row ->
        row
        |> Map.delete(:date_of_birth)
        |> Map.put(:minor, WorkshopPolicy.minor?(row.date_of_birth, workshop.date))
      end)

    %{
      seated: Enum.filter(rows, &(&1.state == "paid")),
      asked: Enum.filter(rows, &(&1.state == "contacted")),
      out: Enum.reject(rows, &(&1.state in Intake.open_states()))
    }
  end

  defp attention(%{status: :due, people: []}), do: [:nobody_waiting]
  defp attention(_next_batch), do: []

  defp name_of(nil), do: nil

  defp name_of(principal_id) do
    from(p in UserProfile,
      where: p.principal_id == ^principal_id,
      limit: 1,
      select: fragment("trim(concat_ws(' ', ?, ?))", p.first_name, p.last_name)
    )
    |> Repo.one()
  end
end
