defmodule Dhc.Invitations.StripePayment do
  @moduledoc """
  Completes the Stripe side of public invitation acceptance.

  The Svelte signup flow collects a Stripe ConfirmationToken client-side. This
  module owns the server-side Stripe calls that attach the SEPA payment method,
  create the membership subscriptions, and confirm the first invoice payments
  before the invitation is converted to a member.

  Acceptance creates the Stripe customer when none is already attached to the
  durable Invitation Acceptance Attempt. Pricing remains read-only.
  """

  alias Dhc.Stripe.Operations
  alias Dhc.Invitations.Pricing

  @doc """
  Creates a Stripe customer for an invitation.

  When an Invitation Acceptance Attempt has no Stripe customer, acceptance
  creates one here so the Membership subscriptions have a customer to attach
  to. The customer is named
  and emailed from the invitation's contact info; `invited_by` metadata records
  the admin who issued the invitation (preserving the pre-ALE-162 metadata
  shape).

  Returns `{:ok, customer_id}` on success or `{:error, reason}` shaped for the
  acceptance transaction's rollback.
  """
  @spec create_customer(String.t(), String.t() | nil, String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def create_customer(email, name, invited_by_id, invitation_id)
      when is_binary(email) and is_binary(name) and is_binary(invited_by_id) do
    body = %{
      "name" => name,
      "email" => email,
      "metadata[invited_by]" => invited_by_id
    }

    idempotency_key = "invitation-accept:#{invitation_id}:customer"

    case Operations.post_customers(body, idempotency_key: idempotency_key) do
      {:ok, %{"id" => id}} when is_binary(id) -> {:ok, id}
      {:ok, body} -> {:error, {:stripe_customer_missing_id, body}}
      {:error, reason} -> {:error, {:stripe_customer, reason}}
    end
  end

  @spec complete(map()) :: :ok | {:error, term()}
  def complete(%{customer_id: customer_id, confirmation_token: confirmation_token} = attrs)
      when is_binary(customer_id) and customer_id != "" and is_binary(confirmation_token) and
             confirmation_token != "" do
    with {:ok, setup_intent} <- create_setup_intent(attrs),
         :ok <- validate_setup_intent(setup_intent),
         {:ok, payment_method_id} <- payment_method_id(setup_intent),
         :ok <-
           report_progress(attrs, %{
             "setup_intent_id" => resource_id(setup_intent),
             "payment_method_id" => payment_method_id
           }),
         {:ok, prices} <- Pricing.membership_price_ids(),
         {:ok, promotion} <- Pricing.resolve_promotion(Map.get(attrs, :coupon_code)),
         :ok <-
           create_membership_subscriptions(
             customer_id,
             payment_method_id,
             prices,
             promotion,
             attrs
           ) do
      :ok
    end
  end

  def complete(%{customer_id: customer_id}) when customer_id in [nil, ""] do
    {:error, :stripe_customer_not_configured}
  end

  def complete(_attrs), do: {:error, :stripe_confirmation_token_required}

  defp create_setup_intent(attrs) do
    form = [
      {"confirm", "true"},
      {"customer", Map.fetch!(attrs, :customer_id)},
      {"confirmation_token", Map.fetch!(attrs, :confirmation_token)},
      {"payment_method_types[]", "sepa_debit"}
    ]

    Operations.post_setup_intents(Map.new(form),
      idempotency_key: idempotency_key(attrs, "setup-intent")
    )
  end

  defp validate_setup_intent(%{"status" => status}) when status in ["succeeded", "processing"],
    do: :ok

  defp validate_setup_intent(%{"status" => status}), do: {:error, {:setup_intent_failed, status}}
  defp validate_setup_intent(_setup_intent), do: {:error, :invalid_setup_intent_response}

  defp payment_method_id(%{"payment_method" => payment_method}) when is_binary(payment_method),
    do: {:ok, payment_method}

  defp payment_method_id(%{"payment_method" => %{"id" => id}}) when is_binary(id), do: {:ok, id}
  defp payment_method_id(_setup_intent), do: {:error, :payment_method_missing}

  defp create_membership_subscriptions(customer_id, payment_method_id, prices, promotion, attrs) do
    with {:ok, monthly} <-
           create_subscription(
             :monthly,
             customer_id,
             payment_method_id,
             prices.monthly.id,
             promotion,
             attrs
           ),
         :ok <- report_subscription_progress(attrs, :monthly, monthly),
         :ok <- maybe_confirm_first_invoice(monthly, payment_method_id, promotion, attrs),
         :ok <- report_progress(attrs, %{"monthly_confirmed" => true}),
         {:ok, annual} <-
           create_subscription(
             :annual,
             customer_id,
             payment_method_id,
             prices.annual.id,
             promotion,
             attrs
           ),
         :ok <- report_subscription_progress(attrs, :annual, annual),
         :ok <- maybe_confirm_first_invoice(annual, payment_method_id, promotion, attrs),
         :ok <- report_progress(attrs, %{"annual_confirmed" => true}) do
      :ok
    end
  end

  defp create_subscription(kind, customer_id, payment_method_id, price_id, promotion, attrs) do
    form =
      [
        {"customer", customer_id},
        {"items[0][price]", price_id},
        {"payment_behavior", "default_incomplete"},
        {"collection_method", "charge_automatically"},
        {"default_payment_method", payment_method_id},
        {"expand[]", "latest_invoice.payments"}
      ]
      |> add_billing_anchor(kind)
      |> maybe_add_discount(promotion)

    Operations.post_subscriptions(Map.new(form),
      idempotency_key: idempotency_key(attrs, "subscription-#{kind}")
    )
  end

  defp add_billing_anchor(form, :monthly),
    do: [{"billing_cycle_anchor_config[day_of_month]", "1"} | form]

  defp add_billing_anchor(form, :annual),
    do: [
      {"billing_cycle_anchor_config[month]", "1"},
      {"billing_cycle_anchor_config[day_of_month]", "7"} | form
    ]

  defp maybe_add_discount(form, %{migration?: true}), do: form
  defp maybe_add_discount(form, %{promotion_code_id: nil}), do: form

  defp maybe_add_discount(form, %{promotion_code_id: promotion_code_id}),
    do: [{"discounts[0][promotion_code]", promotion_code_id} | form]

  defp maybe_confirm_first_invoice(subscription, _payment_method_id, %{migration?: true}, attrs) do
    case latest_invoice(subscription) do
      %{"id" => invoice_id, "amount_due" => amount_due} when is_integer(amount_due) ->
        create_credit_note(invoice_id, amount_due, attrs)

      _ ->
        :ok
    end
    |> then(fn
      :ok -> :ok
      {:ok, _credit_note} -> :ok
      {:error, reason} -> {:error, reason}
    end)
  end

  defp maybe_confirm_first_invoice(subscription, payment_method_id, _promotion, attrs) do
    case payment_intent_id(subscription) do
      nil -> :ok
      payment_intent_id -> confirm_payment_intent(payment_intent_id, payment_method_id, attrs)
    end
  end

  defp latest_invoice(%{"latest_invoice" => invoice}) when is_map(invoice), do: invoice
  defp latest_invoice(_subscription), do: nil

  defp payment_intent_id(subscription) do
    subscription
    |> latest_invoice()
    |> case do
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

  defp confirm_payment_intent(payment_intent_id, payment_method_id, attrs) do
    context = Map.get(attrs, :mandate_context, %{})

    form = [
      {"payment_method", payment_method_id},
      {"mandate_data[customer_acceptance][type]", "online"},
      {"mandate_data[customer_acceptance][online][ip_address]",
       Map.get(context, :ip_address, "")},
      {"mandate_data[customer_acceptance][online][user_agent]", Map.get(context, :user_agent, "")}
    ]

    case Operations.post_payment_intents_intent_confirm(payment_intent_id, Map.new(form),
           idempotency_key: idempotency_key(attrs, "payment-intent-#{payment_intent_id}")
         ) do
      {:ok, _payment_intent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_credit_note(invoice_id, amount, attrs) do
    Operations.post_credit_notes(
      %{"invoice" => invoice_id, "amount" => Integer.to_string(amount)},
      idempotency_key: idempotency_key(attrs, "credit-note-#{invoice_id}")
    )
  end

  defp idempotency_key(attrs, suffix) do
    attempt_id = Map.get(attrs, :attempt_id, Map.get(attrs, :invitation_id, "unknown-attempt"))
    "invitation-acceptance-attempt:#{attempt_id}:#{suffix}"
  end

  defp report_subscription_progress(attrs, kind, subscription) do
    prefix = Atom.to_string(kind)

    progress =
      %{"#{prefix}_subscription_id" => resource_id(subscription)}
      |> maybe_put("#{prefix}_invoice_id", latest_invoice(subscription) |> resource_id())
      |> maybe_put("#{prefix}_payment_intent_id", payment_intent_id(subscription))

    report_progress(attrs, progress)
  end

  defp report_progress(attrs, progress) do
    case Map.get(attrs, :progress) do
      callback when is_function(callback, 1) -> callback.(progress)
      _ -> :ok
    end
  end

  defp resource_id(%{"id" => id}) when is_binary(id), do: id
  defp resource_id(_resource), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
