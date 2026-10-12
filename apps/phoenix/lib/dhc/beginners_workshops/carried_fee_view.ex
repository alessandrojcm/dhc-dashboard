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
    * `available` — what the tab may offer: `CarriedFeePolicy.available/1`
      over the facts `CarriedFeePolicy.facts/1` builds from the same rows
      the boundary locks (ALE-402).
  """

  import Ecto.Query

  alias Dhc.BeginnersWorkshops.{CarriedFee, CarriedFeePolicy, IntakeRefund}
  alias Dhc.Repo
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

  @doc false
  # ALE-402 parity seam: the `CarriedFeePolicy` facts `show/2` decides by.
  @spec facts(binary(), DateTime.t()) ::
          {:ok, CarriedFeePolicy.t()} | {:error, :no_carried_fee | :person_not_found}
  def facts(waitlist_id, %DateTime{} = now) do
    with {:ok, id} <- cast(waitlist_id),
         %WaitlistEntry{} = entry <- Repo.get(WaitlistEntry, id) || {:error, :person_not_found},
         %CarriedFee{} = fee <- fee(id) || {:error, :no_carried_fee} do
      {:ok, policy_facts(fee, entry, now)}
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
    facts = policy_facts(fee, entry, now)

    %{
      id: fee.id,
      status: fee.status,
      origin: fee.origin,
      amount_cents: fee.amount_cents,
      currency: fee.currency,
      imported_paid_text: fee.imported_paid_text,
      stripe_payment_intent_id: fee.stripe_payment_intent_id,
      linked: facts.linked,
      failed_refund: failed && failed_view(failed),
      available: CarriedFeePolicy.available(facts)
    }
  end

  # The fee's latest refund (`IntakeRefund.latest_of_fees_query/1`, as the
  # boundary reads it) and the person's standing.
  defp policy_facts(fee, entry, now) do
    refund =
      case Repo.one(IntakeRefund.latest_of_fees_query([fee.id])) do
        {_id, refund} -> refund
        nil -> nil
      end

    CarriedFeePolicy.facts(fee: fee, refund: refund, entry: entry, now: now)
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
end
