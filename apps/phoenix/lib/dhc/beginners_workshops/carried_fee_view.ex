defmodule Dhc.BeginnersWorkshops.CarriedFeeView do
  @moduledoc """
  ALE-389: one person's Carried Fee as the Waitlist tab shows it — a
  lock-free, actor-free read model (the `WorkshopConsole` shape), advisory
  only: the boundary decides again under the lock.

  It is the person's live (`held` or `applied`) fee, else their latest one,
  with:

    * the original payment it refunds against: a deferral's payment row, or
      an imported fee's Paid cell and the Stripe PaymentIntent staff linked
      (`linked`);
    * `failed_refund` — its latest refund when that failed, has not been
      followed up and the fee is still owed back (the console's Needs
      attention rule);
    * `available` — what the tab may offer: `refund` (a `held` fee of
      someone who has not attended, with a payment to refund against),
      `link_payment` (a live imported fee not yet linked), and `retry`,
      `manual`, `forfeit` for a failed refund.
  """

  import Ecto.Query

  alias Dhc.BeginnersWorkshops.{CarriedFee, IntakeRefund}
  alias Dhc.Repo
  alias Dhc.Waitlist
  alias Dhc.Waitlist.WaitlistEntry

  @type t :: %{
          id: binary(),
          status: String.t(),
          origin: String.t(),
          amount_cents: pos_integer() | nil,
          currency: String.t(),
          imported_paid_text: String.t() | nil,
          stripe_payment_intent_id: String.t() | nil,
          linked: boolean(),
          failed_refund: map() | nil,
          available: [atom()]
        }

  @doc "The person's Carried Fee, or `{:error, :no_carried_fee}` when they never held one."
  @spec show(binary(), DateTime.t()) :: {:ok, t()} | {:error, :no_carried_fee | :person_not_found}
  def show(waitlist_id, %DateTime{} = now) do
    with {:ok, id} <- cast(waitlist_id),
         %WaitlistEntry{} = entry <- Repo.get(WaitlistEntry, id) || {:error, :person_not_found},
         %CarriedFee{} = fee <- fee(id) || {:error, :no_carried_fee} do
      {:ok, view(fee, entry, now)}
    end
  end

  defp cast(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :person_not_found}
    end
  end

  # Live first, then the latest.
  defp fee(waitlist_id) do
    live = CarriedFee.live_statuses()

    from(f in CarriedFee,
      where: f.waitlist_id == ^waitlist_id,
      order_by: [
        desc: fragment("? = ANY(?)", f.status, ^live),
        desc: f.status_changed_at,
        desc: f.created_at
      ],
      limit: 1
    )
    |> Repo.one()
  end

  defp view(fee, entry, now) do
    failed = failed_refund(fee)
    linked = CarriedFee.refundable_through_stripe?(fee)

    %{
      id: fee.id,
      status: fee.status,
      origin: fee.origin,
      amount_cents: fee.amount_cents,
      currency: fee.currency,
      imported_paid_text: fee.imported_paid_text,
      stripe_payment_intent_id: fee.stripe_payment_intent_id,
      linked: linked,
      failed_refund: failed && failed_view(failed),
      available: available(fee, entry, linked, failed, now)
    }
  end

  defp failed_refund(%CarriedFee{status: status} = fee) when status in ["held", "refunded"] do
    from(r in IntakeRefund,
      as: :refund,
      where: r.carried_fee_id == ^fee.id,
      order_by: [desc: r.created_at],
      limit: 1
    )
    |> Repo.one()
    |> case do
      %IntakeRefund{status: "failed", id: id} = refund ->
        if Repo.exists?(from(r in IntakeRefund, where: r.follows_refund_id == ^id)),
          do: nil,
          else: refund

      _none_or_live ->
        nil
    end
  end

  defp failed_refund(_ended_or_applied), do: nil

  defp failed_view(refund),
    do:
      Map.take(refund, [
        :id,
        :workshop_id,
        :amount_cents,
        :currency,
        :reason,
        :last_error,
        :failed_at
      ])

  defp available(fee, entry, linked, failed, now) do
    [
      {:refund, fee.status == "held" and linked and failed == nil and may_refund?(entry, now)},
      {:link_payment,
       fee.status in CarriedFee.live_statuses() and fee.origin == "import" and not linked},
      {:retry, failed != nil},
      {:manual, failed != nil},
      {:forfeit, failed != nil and fee.status == "held"}
    ]
    |> Enum.filter(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  defp may_refund?(%WaitlistEntry{status: "waiting"}, _now), do: true

  defp may_refund?(%WaitlistEntry{status: "removed", removed_at: %DateTime{} = at}, now),
    do: Waitlist.restorable?(at, now)

  defp may_refund?(_entry, _now), do: false
end
