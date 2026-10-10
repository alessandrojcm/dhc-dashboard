defmodule DhcWeb.BeginnersWorkshopCarriedFeesJSON do
  @moduledoc "Renders the Waitlist view's Carried Fees (ALE-388) and one person's Carried Fee (ALE-389)."

  def index(%{carried_fees: carried_fees}), do: %{data: carried_fees}

  @doc "One person's Carried Fee: its original payment, a failed refund, what may be done."
  def show(%{result: fee}) do
    %{
      data: %{
        id: fee.id,
        status: fee.status,
        origin: fee.origin,
        amountCents: fee.amount_cents,
        currency: fee.currency,
        importedPaidText: fee.imported_paid_text,
        stripePaymentIntentId: fee.stripe_payment_intent_id,
        linked: fee.linked,
        failedRefund: fee.failed_refund && failed_refund(fee.failed_refund),
        availableCommands: fee.available
      }
    }
  end

  @doc "The person and their Carried Fee after Refund Carried Fee."
  def refunded(%{result: result}) do
    %{
      data: %{
        waitlistId: result.waitlist_id,
        carriedFee:
          result.carried_fee && %{id: result.carried_fee.id, status: result.carried_fee.status},
        intake:
          result.intake &&
            DhcWeb.BeginnersWorkshopsJSON.intake_command(%{result: result.intake}).data,
        outcome: result.outcome
      }
    }
  end

  @doc "An imported Carried Fee after it is linked to its Stripe payment."
  def linked(%{result: fee}) do
    %{
      data: %{
        id: fee.id,
        status: fee.status,
        amountCents: fee.amount_cents,
        currency: fee.currency,
        stripePaymentIntentId: fee.stripe_payment_intent_id,
        outcome: fee.outcome
      }
    }
  end

  defdelegate refund(assigns), to: DhcWeb.BeginnersWorkshopsJSON
  defdelegate forfeited(assigns), to: DhcWeb.BeginnersWorkshopsJSON

  defp failed_refund(refund) do
    %{
      id: refund.id,
      workshopId: refund.workshop_id,
      amountCents: refund.amount_cents,
      currency: refund.currency,
      reason: refund.reason,
      lastError: refund.last_error,
      failedAt: refund.failed_at
    }
  end
end
