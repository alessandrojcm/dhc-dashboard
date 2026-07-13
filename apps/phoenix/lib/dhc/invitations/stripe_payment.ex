defmodule Dhc.Invitations.StripePayment do
  @moduledoc """
  Completes the Stripe side of public invitation acceptance.

  The Svelte signup flow collects a Stripe ConfirmationToken client-side. This
  module owns the server-side Stripe calls that attach the SEPA payment method,
  create the membership subscriptions, and confirm the first invoice payments
  before the invitation is converted to a member.
  """

  alias Dhc.Stripe.LookupKeys
  alias Dhc.Stripe.Operations

  @migration_code "DHCDASHBOARD"

  @spec complete(map()) :: :ok | {:error, term()}
  def complete(%{customer_id: customer_id, confirmation_token: confirmation_token} = attrs)
      when is_binary(customer_id) and customer_id != "" and is_binary(confirmation_token) and
             confirmation_token != "" do
    with {:ok, setup_intent} <- create_setup_intent(attrs),
         :ok <- validate_setup_intent(setup_intent),
         {:ok, payment_method_id} <- payment_method_id(setup_intent),
         {:ok, prices} <- membership_price_ids(),
         {:ok, promotion} <- resolve_promotion(Map.get(attrs, :coupon_code)),
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

  defp membership_price_ids do
    with {:ok, monthly} <- price_id_for_lookup_key(LookupKeys.monthly()),
         {:ok, annual} <- price_id_for_lookup_key(LookupKeys.annual()) do
      {:ok, %{monthly: monthly, annual: annual}}
    end
  end

  defp price_id_for_lookup_key(lookup_key) do
    case Operations.get_prices(%{}, lookup_keys: [lookup_key], active: true, limit: 1) do
      {:ok, %{"data" => [%{"id" => id} | _]}} when is_binary(id) -> {:ok, id}
      {:ok, %{"data" => []}} -> {:error, {:price_not_found, lookup_key}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, {:invalid_price_response, lookup_key}}
    end
  end

  defp resolve_promotion(nil), do: {:ok, %{migration?: false, promotion_code_id: nil}}
  defp resolve_promotion(""), do: {:ok, %{migration?: false, promotion_code_id: nil}}

  defp resolve_promotion(coupon_code) when is_binary(coupon_code) do
    trimmed = String.trim(coupon_code)

    case Operations.get_promotion_codes(%{}, active: true, code: trimmed, limit: 1) do
      {:ok, %{"data" => [%{"id" => id} | _]}} when is_binary(id) ->
        migration? = String.downcase(trimmed) == String.downcase(migration_code())
        {:ok, %{migration?: migration?, promotion_code_id: if(migration?, do: nil, else: id)}}

      {:ok, %{"data" => []}} ->
        {:error, :invalid_promotion_code}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :invalid_promotion_code_response}
    end
  end

  defp create_membership_subscriptions(customer_id, payment_method_id, prices, promotion, attrs) do
    with {:ok, monthly} <-
           create_subscription(
             :monthly,
             customer_id,
             payment_method_id,
             prices.monthly,
             promotion,
             attrs
           ),
         :ok <- maybe_confirm_first_invoice(monthly, payment_method_id, promotion, attrs),
         {:ok, annual} <-
           create_subscription(
             :annual,
             customer_id,
             payment_method_id,
             prices.annual,
             promotion,
             attrs
           ),
         :ok <- maybe_confirm_first_invoice(annual, payment_method_id, promotion, attrs) do
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
    invitation_id = Map.get(attrs, :invitation_id, "unknown-invitation")
    "invitation-accept:#{invitation_id}:#{suffix}"
  end

  defp migration_code do
    Application.get_env(:dhc, :dashboard_migration_code, @migration_code)
  end
end
