defmodule Dhc.Stripe.SubscriptionPayment do
  @moduledoc """
  Pure decoding shared by the two flows that create a membership subscription
  and settle its first invoice: `Dhc.Membership.Reactivation` and
  `Dhc.Invitations.StripePayment` (ALE-342).

  This module shares *decoding*, not *progression*. It builds the request
  fields both flows send, reads the first invoice's PaymentIntent, checks
  whether an invoice with no PaymentIntent is settled, and classifies a
  PaymentIntent's status. Each caller keeps its own policy: metadata and
  billing anchors, offline vs online mandate, coupons and promotions, attempt
  fences, and how each classified state maps onto its outcome vocabulary.
  Nothing here calls Stripe.
  """

  @typedoc """
  A PaymentIntent's state, as either caller needs it:

    * `:succeeded` — paid.
    * `{:requires_confirmation, id}` — created but never confirmed; the
      caller may confirm it.
    * `{:processing, id}` — submitted, settling asynchronously (SEPA).
    * `{:requires_action, id, next_action_type}` — the customer must act.
    * `{:failed, id, status}` — `requires_payment_method`,
      `requires_capture` or `canceled`.
    * `{:unrecognized, id, status}` — any other status string.
    * `:invalid` — not a PaymentIntent with an id and a status.
  """
  @type payment_intent_state ::
          :succeeded
          | {:requires_confirmation, String.t()}
          | {:processing, String.t()}
          | {:requires_action, String.t(), String.t() | nil}
          | {:failed, String.t(), String.t()}
          | {:unrecognized, String.t(), String.t()}
          | :invalid

  @failed_statuses ["requires_payment_method", "requires_capture", "canceled"]

  @doc """
  The form fields every membership subscription is created with: one price
  item for `customer`, left `incomplete` with a PaymentIntent on its first
  invoice (`payment_behavior=default_incomplete`), charged automatically, and
  with `latest_invoice.payments` expanded so `payment_intent_id/1` can read it.

  Callers append their own metadata, billing anchor, payment method and
  discounts.
  """
  @spec request_fields(String.t(), String.t()) :: [{String.t(), String.t()}]
  def request_fields(customer_id, price_id) do
    [
      {"customer", customer_id},
      {"items[0][price]", price_id},
      {"payment_behavior", "default_incomplete"},
      {"collection_method", "charge_automatically"},
      {"expand[]", "latest_invoice.payments"}
    ]
  end

  @doc "The subscription's expanded latest invoice, or `nil` when absent or unexpanded."
  @spec latest_invoice(map() | nil) :: map() | nil
  def latest_invoice(%{"latest_invoice" => invoice}) when is_map(invoice), do: invoice
  def latest_invoice(_subscription), do: nil

  @doc """
  The PaymentIntent id at `latest_invoice.payments.data[0].payment.payment_intent`,
  whether Stripe returned it as a string or an embedded object; `nil` otherwise.
  """
  @spec payment_intent_id(map() | nil) :: String.t() | nil
  def payment_intent_id(subscription) do
    case latest_invoice(subscription) do
      %{"payments" => %{"data" => [%{"payment" => %{"payment_intent" => id}} | _]}}
      when is_binary(id) ->
        id

      %{"payments" => %{"data" => [%{"payment" => %{"payment_intent" => %{"id" => id}}} | _]}}
      when is_binary(id) ->
        id

      _ ->
        nil
    end
  end

  @doc """
  Checks a first invoice that carries no PaymentIntent: `:ok` when paid,
  `{:error, {:invoice_unsettled, status}}` when it has any other status, and
  `{:error, :invoice_payment_missing}` when there is no expanded invoice.
  """
  @spec validate_paid_invoice(map() | nil) ::
          :ok | {:error, {:invoice_unsettled, String.t()} | :invoice_payment_missing}
  def validate_paid_invoice(subscription) do
    case latest_invoice(subscription) do
      %{"status" => "paid"} -> :ok
      %{"status" => status} -> {:error, {:invoice_unsettled, status}}
      _ -> {:error, :invoice_payment_missing}
    end
  end

  @doc "Classifies a PaymentIntent into a `t:payment_intent_state/0`."
  @spec classify_payment_intent(term()) :: payment_intent_state()
  def classify_payment_intent(%{"status" => "succeeded"}), do: :succeeded

  def classify_payment_intent(%{"id" => id, "status" => "requires_confirmation"})
      when is_binary(id),
      do: {:requires_confirmation, id}

  def classify_payment_intent(%{"id" => id, "status" => "processing"}) when is_binary(id),
    do: {:processing, id}

  def classify_payment_intent(%{"id" => id, "status" => "requires_action"} = intent)
      when is_binary(id),
      do: {:requires_action, id, get_in(intent, ["next_action", "type"])}

  def classify_payment_intent(%{"id" => id, "status" => status})
      when is_binary(id) and status in @failed_statuses,
      do: {:failed, id, status}

  def classify_payment_intent(%{"id" => id, "status" => status})
      when is_binary(id) and is_binary(status),
      do: {:unrecognized, id, status}

  def classify_payment_intent(_payment_intent), do: :invalid
end
