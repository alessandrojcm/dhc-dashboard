defmodule Dhc.BeginnersWorkshops.PeopleView do
  @moduledoc """
  ALE-417: the Waitlist tab's people, as Beginners' Workshops sees them — a
  lock-free, actor-free read model (the `CarriedFeeView` shape), advisory
  only: the boundary decides again under the lock. The Waitlist cannot read
  Beginners' Workshops, so the dashboard asks here for the people a
  Waitlist page lists.

  Each requested id that names a Waitlist entry is present, with:

    * `carried_fee` — the status of the person's live Carried Fee, or `nil`;
    * `available_commands` — `PersonPolicy.available_commands/1`;
    * `refund_choice` — the money an offered Withdraw or Delete must settle
      by refund or forfeit (`PersonPolicy.refund_choice_required?/1`,
      `RefundChoice.of/4`: the payment that paid a Stripe-paid open Intake,
      else the live Carried Fee), or `nil`.

  The facts are `PersonPolicy.facts/1` over the rows the boundary locks
  (`Commands.locked_person_facts/2`); `policy_parity_test.exs` holds them
  equal.
  """

  import Ecto.Query

  alias Dhc.BeginnersWorkshops.{
    CarriedFee,
    Intake,
    IntakePayment,
    IntakeRefund,
    PersonPolicy,
    RefundChoice
  }

  alias Dhc.Repo
  alias Dhc.Waitlist
  alias Dhc.Waitlist.WaitlistEntry

  @type person :: %{
          carried_fee: String.t() | nil,
          available_commands: [PersonPolicy.command()],
          refund_choice: RefundChoice.t() | nil
        }

  @doc "The people `waitlist_ids` name, by Waitlist entry id, judged at `now`."
  @spec list([binary()], DateTime.t()) :: %{binary() => person()}
  def list(waitlist_ids, %DateTime{} = now) do
    waitlist_ids
    |> rows(now)
    |> Map.new(fn {id, row} -> {id, view(row)} end)
  end

  @doc false
  # ALE-417 parity seam: the `PersonPolicy` facts `list/2` decides by.
  @spec facts([binary()], DateTime.t()) :: %{binary() => PersonPolicy.t()}
  def facts(waitlist_ids, %DateTime{} = now) do
    waitlist_ids
    |> rows(now)
    |> Map.new(fn {id, row} -> {id, row.facts} end)
  end

  defp view(%{facts: facts, live_fee: live, paying: paying}) do
    %{
      carried_fee: live && live.status,
      available_commands: PersonPolicy.available_commands(facts),
      refund_choice:
        RefundChoice.of(
          PersonPolicy.refund_choice_required?(facts),
          facts.intake,
          paying,
          live && Map.take(live, [:amount_cents, :currency])
        )
    }
  end

  defp rows([], _now), do: %{}

  defp rows(waitlist_ids, now) do
    ids = Enum.uniq(waitlist_ids)
    entries = Repo.all(from(e in WaitlistEntry, where: e.id in ^ids))
    intakes = open_intakes(ids)
    fees = fees(ids)
    deletable = Waitlist.deletable_ids(ids)

    judged =
      Map.new(entries, fn entry ->
        person_fees = Map.get(fees, entry.id, [])
        live = Enum.find(person_fees, &(&1.status in CarriedFee.live_statuses()))

        {entry.id,
         %{entry: entry, live: live, latest: if(live == nil, do: List.first(person_fees))}}
      end)

    refunds =
      judged
      |> Map.values()
      |> Enum.flat_map(&List.wrap(&1.live || &1.latest))
      |> Enum.map(& &1.id)
      |> IntakeRefund.latest_of_fees_query()
      |> Repo.all()
      |> Map.new()

    paying = paying_payments(intakes |> Map.values() |> Enum.map(& &1.id))

    Map.new(judged, fn {id, %{entry: entry, live: live, latest: latest}} ->
      intake = Map.get(intakes, id)
      fee = live || latest

      facts =
        PersonPolicy.facts(
          intake: intake,
          entry: entry,
          live_fee: live,
          latest_fee: latest,
          fee_refund: fee && Map.get(refunds, fee.id),
          deletable: MapSet.member?(deletable, id),
          now: now
        )

      {id, %{facts: facts, live_fee: live, paying: intake && Map.get(paying, intake.id)}}
    end)
  end

  # Each person's open Intake (at most one), by Waitlist id.
  defp open_intakes(ids) do
    from(i in Intake, where: i.waitlist_id in ^ids and i.state in ^Intake.open_states())
    |> Repo.all()
    |> Map.new(&{&1.waitlist_id, &1})
  end

  # Every Carried Fee of each person, latest first (the boundary's
  # `latest_fee` order), by Waitlist id.
  defp fees(ids) do
    from(f in CarriedFee,
      where: f.waitlist_id in ^ids,
      order_by: [desc: f.status_changed_at, desc: f.created_at]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.waitlist_id)
  end

  # The payment that paid each Intake (the boundary's `paying_payment/1`
  # rule: its first `paid` row not refunded automatically), with what it
  # actually took.
  defp paying_payments([]), do: %{}

  defp paying_payments(intake_ids) do
    automatic = IntakeRefund.automatic_reasons()

    from(p in IntakePayment,
      as: :payment,
      where: p.intake_id in ^intake_ids and p.status == "paid",
      where:
        not exists(
          from(r in IntakeRefund,
            where: r.payment_id == parent_as(:payment).id and r.reason in ^automatic
          )
        ),
      distinct: p.intake_id,
      order_by: [asc: p.intake_id, asc: p.paid_at, asc: p.id],
      select:
        {p.intake_id,
         %{
           amount_cents: coalesce(p.amount_received_cents, p.amount_cents),
           currency: coalesce(p.currency_received, p.currency)
         }}
    )
    |> Repo.all()
    |> Map.new()
  end
end
