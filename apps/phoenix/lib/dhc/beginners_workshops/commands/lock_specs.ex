defmodule Dhc.BeginnersWorkshops.Commands.LockSpecs do
  @moduledoc """
  The `with_locked/2` spec pieces several command families lock an Intake,
  a person or their Carried Fee with (ALE-405). Each returns a query (or a
  spec map, or `nil` for a level the command skips); the lock order is
  still `Commands.Protocol`'s.

    * `intake_spec/2` — Beginners' Workshop → Intake, with a payment level
      (`Commands.Payments`, `Commands.IntakeCommands`);
    * `open_payment/1` — an Intake's live Seat Hold (`Commands.Payments`,
      `Commands.IntakeCommands`);
    * `paying_payment/1` — the payment that paid an Intake
      (`Commands.IntakeCommands`);
    * `entry_query/1` — a peeked Intake's Waitlist entry
      (`Commands.Payments`, `Commands.IntakeCommands`);
    * `live_fee_query/1` — the person's live Carried Fee
      (`Commands.Batches`, `Commands.Refunds`, `Commands.IntakeCommands`,
      `Commands.People`);
    * `locked_intake_fee/1` — the Carried Fee level for a command that
      locked an Intake (`Commands.Payments`, `Commands.IntakeCommands`).

  Reach lets only `Commands` and `Commands.*` call this module.
  """

  import Ecto.Query

  import Dhc.BeginnersWorkshops.Commands.Protocol, only: [required: 1]

  alias Dhc.BeginnersWorkshops.{
    BeginnersWorkshop,
    CarriedFee,
    Intake,
    IntakePayment,
    IntakeRefund
  }

  alias Dhc.Waitlist.WaitlistEntry

  @doc false
  @spec intake_spec(%{workshop_id: binary(), intake_id: binary()}, term()) :: map()
  def intake_spec(%{workshop_id: workshop_id, intake_id: intake_id}, payment) do
    %{
      workshop: required(from(w in BeginnersWorkshop, where: w.id == ^workshop_id)),
      intake: required(from(i in Intake, where: i.id == ^intake_id)),
      payment: payment
    }
  end

  @doc false
  @spec open_payment(binary()) :: Ecto.Query.t()
  def open_payment(intake_id),
    do: from(p in IntakePayment, where: p.intake_id == ^intake_id and p.status == "open")

  @doc false
  # The payment that paid an Intake: its `paid` row that was not refunded
  # automatically (a completion after the Intake had closed, or one that
  # failed the amount check, is refunded on its own and never paid it).
  @spec paying_payment(binary()) :: Ecto.Query.t()
  def paying_payment(intake_id) do
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

  @doc false
  @spec entry_query(%{waitlist_id: binary() | nil}) :: Ecto.Query.t() | nil
  def entry_query(%{waitlist_id: nil}), do: nil
  def entry_query(%{waitlist_id: id}), do: from(e in WaitlistEntry, where: e.id == ^id)

  @doc false
  # The person's live (`held` or `applied`) Carried Fee: at most one.
  @spec live_fee_query(binary()) :: Ecto.Query.t()
  def live_fee_query(waitlist_id),
    do:
      from(f in CarriedFee,
        where: f.waitlist_id == ^waitlist_id and f.status in ^CarriedFee.live_statuses()
      )

  @doc false
  # The Carried Fee level for a command that locked an Intake.
  @spec locked_intake_fee(map()) :: Ecto.Query.t() | nil
  def locked_intake_fee(%{intake: %Intake{waitlist_id: id}}) when is_binary(id),
    do: live_fee_query(id)

  def locked_intake_fee(_locked), do: nil
end
