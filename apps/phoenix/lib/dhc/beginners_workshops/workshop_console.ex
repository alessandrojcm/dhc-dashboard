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
    * `roster` — Intakes grouped by meaning: before finalisation `seated`
      (paid), `asked` (contacted, not paid yet) and `out`; after it
      (ALE-391) `attended`, `no_show` and `out`. Each Intake with a live
      Seat Hold carries when its hold runs out (ALE-381), each paid Intake
      its door check-in time (ALE-390), and each Intake with a refund
      carries its latest refund's status, method and whether it was
      automatic (ALE-382);
    * `failed_refunds` — the Needs attention list of refunds that failed
      and have not been followed up (Retry or Record manual refund), oldest
      first (ALE-382);
    * `finalisation` (ALE-391) — `nil` until Attendance Finalisation, then
      when, who pressed Finish (`nil`: automatically at the end of the day)
      and when the Follow-up goes out (`WorkshopPolicy.follow_up_at/1`);
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
    DoorView,
    Intake,
    IntakePayment,
    IntakeRefund,
    WorkshopFacts,
    WorkshopPolicy,
    WorkshopProjection
  }

  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile

  # Every state with a roster group of its own; the rest are `out`.
  @not_out ~w(contacted paid attended no_show)

  @type t :: %{
          workshop: WorkshopProjection.t(),
          batches: [map()],
          pause: map(),
          next_batch: map(),
          roster: %{
            seated: [map()],
            asked: [map()],
            attended: [map()],
            no_show: [map()],
            out: [map()]
          },
          finalisation:
            %{at: DateTime.t(), by: String.t() | nil, follow_up_at: DateTime.t()} | nil,
          failed_refunds: [map()],
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
         failed_refunds: failed_refunds(id),
         attention: attention(next_batch),
         finalisation: finalisation(workshop),
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
    refunds = latest_refunds(workshop.id)

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
          checked_in_at: i.checked_in_at,
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
        |> Map.put(:refund, Map.get(refunds, row.id))
      end)

    %{
      seated: Enum.filter(rows, &(&1.state == "paid")),
      asked: Enum.filter(rows, &(&1.state == "contacted")),
      attended: Enum.filter(rows, &(&1.state == "attended")),
      no_show: Enum.filter(rows, &(&1.state == "no_show")),
      out: Enum.reject(rows, &(&1.state in @not_out))
    }
  end

  defp finalisation(%BeginnersWorkshop{status: "finalised"} = workshop) do
    %{
      at: workshop.finalised_at,
      by: DoorView.finaliser_name(workshop.finalised_by_principal_id),
      follow_up_at: WorkshopPolicy.follow_up_at(workshop)
    }
  end

  defp finalisation(%BeginnersWorkshop{}), do: nil

  # The latest refund of each Intake, by when it was requested.
  defp latest_refunds(workshop_id) do
    from(r in IntakeRefund,
      where: r.workshop_id == ^workshop_id,
      order_by: [asc: r.requested_at, asc: r.created_at]
    )
    |> Repo.all()
    |> Map.new(fn refund ->
      {refund.intake_id,
       %{
         status: refund.status,
         method: refund.method,
         automatic: IntakeRefund.automatic?(refund),
         amount_cents: refund.amount_cents,
         currency: refund.currency
       }}
    end)
  end

  defp failed_refunds(workshop_id) do
    from(r in IntakeRefund,
      join: i in Intake,
      on: i.id == r.intake_id,
      left_join: p in UserProfile,
      on: p.waitlist_id == i.waitlist_id and not is_nil(i.waitlist_id),
      left_join: f in IntakeRefund,
      on: f.follows_refund_id == r.id,
      where: r.workshop_id == ^workshop_id and r.status == "failed" and is_nil(f.id),
      order_by: [asc: r.failed_at, asc: r.id],
      select: %{
        id: r.id,
        intake_id: r.intake_id,
        first_name: p.first_name,
        last_name: p.last_name,
        amount_cents: r.amount_cents,
        currency: r.currency,
        reason: r.reason,
        failed_at: r.failed_at
      }
    )
    |> Repo.all()
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
