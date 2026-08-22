defmodule Dhc.Membership.Reactivation do
  @moduledoc """
  Stripe choreography for reactivating an inactive member (ALE-251).

  Creates fresh monthly + annual membership subscriptions against the
  member's previously saved SEPA Direct Debit payment method and confirms
  both first invoices off-session. The member's existing mandate is reused —
  no mandate or confirmation token is collected from them. Because the
  subscription's first PaymentIntent carries `setup_future_usage`, Stripe
  requires acceptance metadata on confirm; we send
  `customer_acceptance[type=offline]` (operator-initiated charge under the
  standing agreement) rather than fabricating online acceptance details.

  Billing semantics (verified against Stripe's current docs, see ALE-251):

  * `payment_behavior: default_incomplete` leaves the subscription
    `incomplete` with a PaymentIntent on its first invoice; confirming that
    intent activates the subscription.
  * A future `billing_cycle_anchor` raises a prorated invoice immediately for
    the remainder up to the anchor, then full periods bill from it. The
    operator-chosen start date anchors the monthly subscription this way; a
    start date of today needs no anchor (the full period starts now).
  * The annual subscription keeps signup semantics: anchored at next January
    7 via `billing_cycle_anchor_config`, so its immediate prorated invoice is
    "the annual fee charged for the remainder of this year".
  * SEPA settles asynchronously: a confirmed intent reports `processing`,
    which surfaces as a pending outcome, not a failure.

  Retries are idempotent: every mutating call carries an idempotency key
  derived from member id + requested start date (+ call suffix), so a replay
  returns Stripe's stored response instead of duplicating subscriptions.

  This module deliberately mirrors `Dhc.Invitations.StripePayment`'s proven
  form-encoding and outcome vocabulary while staying independent of the
  invitation domain: different metadata keys, different idempotency
  namespace, no mandate collection, and no acceptance-attempt progress
  persistence.
  """

  alias Dhc.Stripe.LookupKeys
  alias Dhc.Stripe.Operations

  require Logger

  @annual_anchor_month "1"
  @annual_anchor_day "7"
  # Integer twins for date math (the string pair above feeds form encoding).
  @annual_anchor_month_int 1
  @annual_anchor_day_int 7
  @metadata_purpose "membership-reactivation"
  @currency "EUR"

  # Shared with Dhc.Membership's guard so it can recognise subscriptions
  # created by this command.
  @doc false
  def purpose, do: @metadata_purpose

  @type outcome :: :ok | {:pending, map()} | {:error, term()}

  @spec activate(map()) ::
          {:ok, map()} | {:error, :no_saved_payment_method | :stripe_error}
  def activate(
        %{customer_id: customer_id, member_id: member_id, start_date: %Date{} = start_date} =
          attrs
      ) do
    with {:ok, payment_method_id} <- find_saved_sepa_method(customer_id),
         {:ok, prices} <- membership_prices(),
         {:ok, monthly} <-
           create_subscription(
             :monthly,
             customer_id,
             payment_method_id,
             prices.monthly,
             start_date,
             attrs
           ),
         monthly_outcome = maybe_confirm_first_invoice(monthly, payment_method_id, attrs),
         :ok <- continue_after_outcome(monthly_outcome),
         {:ok, annual} <-
           create_subscription(
             :annual,
             customer_id,
             payment_method_id,
             prices.annual,
             start_date,
             attrs
           ),
         annual_outcome = maybe_confirm_first_invoice(annual, payment_method_id, attrs) do
      {:ok,
       build_result(member_id, monthly, annual, combine_outcomes(monthly_outcome, annual_outcome))}
    else
      {:error, :no_saved_payment_method} = error ->
        error

      {:error, reason} ->
        Logger.error(
          "[membership.reactivation] Reactivation failed: #{inspect(reason)}",
          member_id: Map.get(attrs, :member_id),
          customer_id: customer_id,
          reason: inspect(reason)
        )

        {:error, :stripe_error}
    end
  end

  def activate(_attrs), do: {:error, :stripe_error}

  @doc """
  Computes what a reactivation starting on `start_date` would charge, via
  Stripe's invoice-preview machinery — the same endpoint signup pricing uses
  — so the operator sees exact amounts before confirming (ALE-254). No local
  arithmetic: Stripe prices the hypothetical subscriptions.

  The preview parameters mirror `activate/1` exactly:

  * Monthly first invoice anchored at the operator-chosen start date when it
    is in the future; a start of today needs no anchor (full period starts
    immediately).
  * Annual first invoice prorated to the next January 7 anchor. The actual
    subscription resolves `billing_cycle_anchor_config` to that date at the
    CREATION time-of-day UTC (verified against real Stripe), so the preview
    passes the same resolved timestamp instead of midnight.
  * Recurring fees come from previews dated at each period start, which
    return the full upcoming period's subtotal.

  Any Stripe failure aborts the whole computation with `{:error,
  :stripe_error}`; the UI hides the amounts and keeps the form usable.
  """
  @spec preview_amounts(Date.t()) ::
          {:ok,
           %{
             dueToday: %{amount: non_neg_integer(), currency: String.t(), precision: 2},
             monthlyFee: %{amount: non_neg_integer(), currency: String.t(), precision: 2},
             annualFee: %{amount: non_neg_integer(), currency: String.t(), precision: 2}
           }}
          | {:error, :stripe_error}
  def preview_amounts(%Date{} = start_date) do
    # membership_prices/0 models internal failure shapes for activate/1's
    # logging; a preview must collapse every Stripe failure into the single
    # error the API contract exposes (a partial price list is as useless as
    # no amounts at all).
    case membership_prices() do
      {:ok, prices} ->
        run_amount_previews(prices, start_date)

      {:error, reason} ->
        Logger.error("[membership.reactivation] Membership price lookup failed",
          reason: inspect(reason)
        )

        {:error, :stripe_error}
    end
  end

  defp run_amount_previews(prices, %Date{} = start_date) do
    annual_anchor = next_annual_anchor_unix()
    start_unix = date_to_unix(start_date)

    calls = [
      monthly_initial: fn ->
        # Same rule add_billing_anchor/3 applies at creation time.
        date_opts =
          if Date.compare(start_date, Date.utc_today()) == :gt,
            do: [billing_cycle_anchor: start_unix],
            else: []

        preview_invoice(prices.monthly, date_opts)
      end,
      annual_initial: fn ->
        preview_invoice(prices.annual, billing_cycle_anchor: annual_anchor)
      end,
      monthly_recurring: fn ->
        preview_invoice(prices.monthly, start_date: start_unix)
      end,
      annual_recurring: fn ->
        preview_invoice(prices.annual, start_date: annual_anchor)
      end
    ]

    calls
    |> Task.async_stream(
      fn {name, preview} -> {name, preview.()} end,
      ordered: false,
      timeout: :infinity
    )
    |> collect_previews()
    |> build_amounts()
  end

  defp preview_invoice(price_id, date_opts) do
    form =
      Map.merge(
        %{
          "subscription_details[items][0][price]" => price_id,
          "subscription_details[items][0][quantity]" => "1"
        },
        Map.new(date_opts, fn {key, unix} ->
          {"subscription_details[#{key}]", Integer.to_string(unix)}
        end)
      )

    case Operations.post_invoices_create_preview(form) do
      {:ok, invoice} -> {:ok, invoice}
      {:error, reason} -> {:error, {:invoice_preview_failed, reason}}
    end
  end

  # Fails the whole computation on the first unsuccessful preview; a partial
  # amount summary would be worse than none. Results are keyed by call name —
  # the stream is unordered.
  defp collect_previews(stream) do
    Enum.reduce_while(stream, %{}, fn
      {:ok, {name, {:ok, invoice}}}, acc ->
        {:cont, Map.put(acc, name, invoice)}

      {:ok, {name, {:error, reason}}}, _acc ->
        Logger.error("[membership.reactivation] Invoice preview failed",
          kind: name,
          reason: inspect(reason)
        )

        {:halt, {:error, :stripe_error}}

      {:exit, reason}, _acc ->
        Logger.error("[membership.reactivation] Invoice preview task exited",
          reason: inspect(reason)
        )

        {:halt, {:error, :stripe_error}}
    end)
  end

  defp build_amounts({:error, :stripe_error}), do: {:error, :stripe_error}

  defp build_amounts(previews) when is_map(previews) do
    with {:ok, monthly_first} <- Map.fetch(previews, :monthly_initial),
         {:ok, annual_first} <- Map.fetch(previews, :annual_initial),
         {:ok, monthly_recurring} <- Map.fetch(previews, :monthly_recurring),
         {:ok, annual_recurring} <- Map.fetch(previews, :annual_recurring) do
      {:ok,
       %{
         dueToday:
           money(
             invoice_amount(monthly_first, "amount_due") +
               invoice_amount(annual_first, "amount_due")
           ),
         monthlyFee: money(invoice_amount(monthly_recurring, "subtotal")),
         annualFee: money(invoice_amount(annual_recurring, "subtotal"))
       }}
    else
      _ -> {:error, :stripe_error}
    end
  end

  defp invoice_amount(invoice, key), do: Map.get(invoice, key, 0) || 0

  defp money(amount),
    do: %{amount: amount, currency: @currency, precision: 2}

  # billing_cycle_anchor_config resolves to the next occurrence of Jan 7 at
  # the subscription's creation time-of-day UTC (verified against real Stripe
  # in the integration test); mirroring it here keeps the prorated preview
  # within cents of the actual charge.
  defp next_annual_anchor_unix do
    today = Date.utc_today()
    candidate = Date.new!(today.year, 1, @annual_anchor_day_int)

    date =
      if Date.compare(candidate, today) == :gt,
        do: candidate,
        else: Date.new!(today.year + 1, @annual_anchor_month_int, @annual_anchor_day_int)

    now = Time.utc_now()

    DateTime.new!(date, %{now | microsecond: {0, 0}}, "Etc/UTC")
    |> DateTime.to_unix()
  end

  # Lists the customer's saved SEPA debit methods. Any listed method is
  # usable: it carries the mandate from when the member paid by card-free
  # signup, so off-session confirmation works without re-collecting anything.
  defp find_saved_sepa_method(customer_id) do
    case saved_sepa_method(customer_id) do
      {:ok, %{id: payment_method_id}} -> {:ok, payment_method_id}
      {:ok, nil} -> {:error, :no_saved_payment_method}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Summarises the customer's first saved SEPA debit method (the one a
  reactivation would charge). `{:ok, nil}` when none exists; this is a normal
  outcome for the preview read (ALE-252), not an error.
  """
  @spec saved_sepa_method(String.t()) ::
          {:ok,
           %{
             id: String.t(),
             last4: String.t() | nil,
             bank_code: String.t() | nil,
             country: String.t() | nil
           }}
          | {:ok, nil}
          | {:error, :stripe_error}
  def saved_sepa_method(customer_id) do
    case Operations.get_customers_customer_payment_methods(customer_id, %{},
           type: "sepa_debit",
           limit: 10
         ) do
      {:ok, %{"data" => [%{"id" => payment_method_id} = method | _]}}
      when is_binary(payment_method_id) ->
        {:ok, summarise_sepa_method(method)}

      {:ok, %{"data" => []}} ->
        {:ok, nil}

      {:error, reason} ->
        Logger.error("[membership.reactivation] Saved SEPA method lookup failed",
          customer_id: customer_id,
          reason: inspect(reason)
        )

        {:error, :stripe_error}

      other ->
        Logger.error("[membership.reactivation] Unexpected saved-method response",
          customer_id: customer_id,
          reason: inspect(other)
        )

        {:error, :stripe_error}
    end
  end

  defp summarise_sepa_method(%{"id" => id} = method) do
    sepa_debit = Map.get(method, "sepa_debit", %{})

    %{
      id: id,
      last4: Map.get(sepa_debit, "last4"),
      bank_code: Map.get(sepa_debit, "bank_code"),
      country: Map.get(sepa_debit, "country")
    }
  end

  defp membership_prices do
    with {:ok, monthly} <- price_for_lookup_key(LookupKeys.monthly()),
         {:ok, annual} <- price_for_lookup_key(LookupKeys.annual()) do
      {:ok, %{monthly: monthly, annual: annual}}
    end
  end

  defp price_for_lookup_key(lookup_key) do
    case Operations.get_prices(%{}, lookup_keys: [lookup_key], active: true, limit: 1) do
      {:ok, %{"data" => [%{"id" => price_id} | _]}} when is_binary(price_id) ->
        {:ok, price_id}

      {:ok, %{"data" => []}} ->
        Logger.error("[membership.reactivation] No active Stripe price for lookup key",
          lookup_key: lookup_key
        )

        {:error, {:price_not_found, lookup_key}}

      {:error, reason} ->
        {:error, {:stripe, reason}}

      _ ->
        {:error, {:invalid_price_response, lookup_key}}
    end
  end

  defp create_subscription(kind, customer_id, payment_method_id, price_id, start_date, attrs) do
    # NOTE: the operator principal id is deliberately NOT part of this
    # request. Idempotency keys are scoped to member + start date (per
    # ALE-251), and Stripe rejects key reuse with a modified body — including
    # the operator would turn every retry from a different session into a
    # spurious 400.
    form =
      [
        {"customer", customer_id},
        {"items[0][price]", price_id},
        {"payment_behavior", "default_incomplete"},
        {"collection_method", "charge_automatically"},
        {"default_payment_method", payment_method_id},
        {"expand[]", "latest_invoice.payments"},
        {"metadata[purpose]", @metadata_purpose},
        {"metadata[reactivation_start_date]", Date.to_iso8601(start_date)},
        {"metadata[member_id]", Map.get(attrs, :member_id)},
        {"metadata[kind]", Atom.to_string(kind)}
      ]
      |> add_billing_anchor(kind, start_date)

    case Operations.post_subscriptions(Map.new(form),
           idempotency_key: idempotency_key(attrs, "subscription-#{kind}")
         ) do
      {:ok, subscription} ->
        {:ok, subscription}

      {:error, reason} ->
        Logger.error("[membership.reactivation] Subscription creation failed",
          kind: kind,
          customer_id: customer_id,
          reason: inspect(reason)
        )

        {:error, {:subscription_creation_failed, kind, reason}}
    end
  end

  # Monthly honours the operator-chosen start date as a raw billing cycle
  # anchor (must be future); annual keeps the calendar anchor signup uses so
  # renewals land each January.
  defp add_billing_anchor(form, :monthly, start_date) do
    if Date.compare(start_date, Date.utc_today()) == :gt do
      [{"billing_cycle_anchor", Integer.to_string(date_to_unix(start_date))} | form]
    else
      form
    end
  end

  defp add_billing_anchor(form, :annual, _start_date) do
    [
      {"billing_cycle_anchor_config[month]", @annual_anchor_month},
      {"billing_cycle_anchor_config[day_of_month]", @annual_anchor_day}
      | form
    ]
  end

  defp maybe_confirm_first_invoice(subscription, payment_method_id, attrs) do
    case payment_intent_id(subscription) do
      nil -> validate_paid_invoice(subscription)
      payment_intent_id -> confirm_payment_intent(payment_intent_id, payment_method_id, attrs)
    end
  end

  # Off-session confirm against the saved method. The subscription's first
  # PaymentIntent carries `setup_future_usage`, and real Stripe rejects a
  # sepa_debit confirm for such intents unless acceptance metadata is
  # supplied ("When confirming a PaymentIntent with a `sepa_debit`
  # PaymentMethod and `setup_future_usage`, `mandate_data` is required").
  #
  # We satisfy that with `customer_acceptance[type=offline]`: the charge
  # happens under the member's EXISTING mandate (operator-initiated, no
  # browser session), so no new acceptance evidence is collected from the
  # member. This is verified against Stripe test mode — see ALE-251.
  defp confirm_payment_intent(payment_intent_id, payment_method_id, attrs) do
    form = %{
      "payment_method" => payment_method_id,
      "mandate_data[customer_acceptance][type]" => "offline"
    }

    case Operations.post_payment_intents_intent_confirm(payment_intent_id, form,
           idempotency_key: idempotency_key(attrs, "payment-intent-#{payment_intent_id}")
         ) do
      {:ok, payment_intent} -> payment_intent_outcome(payment_intent)
      {:error, reason} -> {:error, {:payment_intent_confirm_failed, payment_intent_id, reason}}
    end
  end

  defp payment_intent_outcome(%{"status" => "succeeded"}), do: :ok

  defp payment_intent_outcome(%{"id" => id, "status" => "processing"}) do
    pending(id, "pending", nil)
  end

  defp payment_intent_outcome(%{"id" => id, "status" => "requires_action"} = intent) do
    pending(id, "needs_action", get_in(intent, ["next_action", "type"]))
  end

  defp payment_intent_outcome(%{"id" => id, "status" => status})
       when status in ["requires_payment_method", "requires_capture", "canceled"] do
    pending(id, "terminal", status)
  end

  defp payment_intent_outcome(%{"id" => id, "status" => status}) do
    pending(id, "terminal", status)
  end

  defp pending(id, state, detail) do
    {:pending,
     %{
       "payment_state" => state,
       "payment_intent_id" => id,
       "payment_detail" => detail
     }}
  end

  # A pending SEPA submission must not abort the flow — the annual
  # subscription still has to be created before the combined result is
  # reported. Terminal pendings keep flowing to the response so the operator
  # sees the charge did not go through.
  defp continue_after_outcome(:ok), do: :ok
  defp continue_after_outcome({:pending, _state}), do: :ok
  defp continue_after_outcome(outcome), do: outcome

  defp combine_outcomes(:ok, :ok), do: :ok
  defp combine_outcomes(:ok, {:pending, _state} = annual), do: annual
  defp combine_outcomes({:pending, _state} = monthly, :ok), do: monthly

  defp combine_outcomes({:pending, _} = monthly, {:pending, _}),
    do: monthly

  defp validate_paid_invoice(subscription) do
    case latest_invoice(subscription) do
      %{"status" => "paid"} -> :ok
      %{"status" => status} -> {:error, {:invoice_unsettled, status}}
      _ -> {:error, :invoice_payment_missing}
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

  defp build_result(member_id, monthly, annual, outcome) do
    %{
      memberId: member_id,
      paymentState: payment_state(outcome),
      monthlySubscriptionId: resource_id(monthly),
      annualSubscriptionId: resource_id(annual)
    }
  end

  defp payment_state(:ok), do: "succeeded"

  defp payment_state({:pending, %{"payment_state" => state}}) when is_binary(state), do: state

  defp date_to_unix(date) do
    date |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()
  end

  defp idempotency_key(attrs, suffix) do
    "membership-reactivate:#{Map.fetch!(attrs, :member_id)}:#{Date.to_iso8601(Map.fetch!(attrs, :start_date))}:#{suffix}"
  end

  defp resource_id(%{"id" => id}) when is_binary(id), do: id
  defp resource_id(_resource), do: nil
end
