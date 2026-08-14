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
  def create_customer(email, name, invited_by_id, acceptance_attempt_id)
      when is_binary(email) and is_binary(name) and is_binary(invited_by_id) do
    body = %{
      "name" => name,
      "email" => email,
      "metadata[invited_by]" => invited_by_id,
      "metadata[acceptance_attempt_id]" => acceptance_attempt_id
    }

    idempotency_key = "invitation-accept:#{acceptance_attempt_id}:customer"

    case find_customer_by_attempt(email, acceptance_attempt_id) do
      {:ok, id} when is_binary(id) ->
        {:ok, id}

      {:ok, nil} ->
        case Operations.post_customers(body, idempotency_key: idempotency_key) do
          {:ok, %{"id" => id}} when is_binary(id) -> {:ok, id}
          {:ok, response} -> {:error, {:stripe_customer_missing_id, response}}
          {:error, reason} -> {:error, {:stripe_customer, reason}}
        end

      {:error, reason} ->
        {:error, {:stripe_customer, reason}}
    end
  end

  @spec complete(map()) :: :ok | {:pending, map()} | {:error, term()}
  def complete(%{customer_id: customer_id, complimentary: true} = attrs)
      when is_binary(customer_id) and customer_id != "" do
    with {:ok, plan} <- payment_plan(attrs),
         true <- plan.requirement == :complimentary,
         :ok <- create_membership_subscriptions(customer_id, nil, plan, attrs) do
      :ok
    else
      false -> {:error, :complimentary_payment_plan_required}
      {:error, _reason} = error -> error
    end
  end

  def complete(%{customer_id: customer_id, payment_method_id: payment_method_id} = attrs)
      when is_binary(customer_id) and customer_id != "" and is_binary(payment_method_id) and
             payment_method_id != "" do
    with {:ok, plan} <- payment_plan(attrs),
         :ok <-
           create_membership_subscriptions(
             customer_id,
             payment_method_id,
             plan,
             attrs
           ) do
      :ok
    end
  end

  def complete(%{customer_id: customer_id, confirmation_token: confirmation_token} = attrs)
      when is_binary(customer_id) and customer_id != "" and is_binary(confirmation_token) and
             confirmation_token != "" do
    with {:ok, stripe_state} <- reconcile_provider_progress(attrs),
         attrs = Map.put(attrs, :stripe_state, stripe_state),
         {:ok, setup_intent} <- ensure_setup_intent(attrs, stripe_state),
         :ok <- validate_setup_intent(setup_intent),
         {:ok, payment_method_id} <- payment_method_id(setup_intent),
         :ok <-
           report_progress(attrs, %{
             "setup_intent_id" => resource_id(setup_intent),
             "payment_method_id" => payment_method_id
           }),
         {:ok, plan} <- payment_plan(attrs),
         :ok <-
           create_membership_subscriptions(
             customer_id,
             payment_method_id,
             plan,
             attrs
           ) do
      :ok
    end
  end

  def complete(%{customer_id: customer_id}) when customer_id in [nil, ""] do
    {:error, :stripe_customer_not_configured}
  end

  def complete(_attrs), do: {:error, :stripe_confirmation_token_required}

  @doc """
  Cancels subscriptions created by an acceptance attempt before that attempt is
  concluded and a replacement attempt is allowed to start.

  Stripe DELETE requests are idempotent, so interrupted cleanup can safely be
  retried by the acceptance recovery worker.
  """
  @spec cancel_membership(map()) :: :ok | {:error, term()}
  def cancel_membership(stripe_state) when is_map(stripe_state) do
    with {:ok, discovered_ids} <- discover_subscription_ids(stripe_state) do
      errors =
        ([stripe_state["monthly_subscription_id"], stripe_state["annual_subscription_id"]] ++
           discovered_ids)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.reduce([], fn subscription_id, errors ->
          case cancel_subscription(subscription_id) do
            :ok -> errors
            {:error, reason} -> [{subscription_id, reason} | errors]
          end
        end)

      case errors do
        [] -> :ok
        errors -> {:error, {:subscription_cleanup_failed, Enum.reverse(errors)}}
      end
    end
  end

  defp cancel_subscription(subscription_id) do
    case Operations.delete_subscriptions_subscription_exposed_id(subscription_id, %{
           "invoice_now" => false,
           "prorate" => false
         }) do
      {:ok, _subscription} ->
        :ok

      {:error, %Dhc.Stripe.Error{error: %{code: "resource_missing"}}} ->
        :ok

      {:error, {:stripe_api, 404, %{"error" => %{"code" => "resource_missing"}}}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def retryable_failure?({:stripe_customer, reason}), do: retryable_failure?(reason)

  def retryable_failure?({:stripe_api, status, _body})
      when status in [408, 409, 429] or status >= 500,
      do: true

  def retryable_failure?({:http_error, _reason}), do: true
  def retryable_failure?({:progress_persistence, _reason}), do: true
  def retryable_failure?(:stale_acceptance_operation), do: true
  def retryable_failure?(:timeout), do: true
  def retryable_failure?(_reason), do: false

  defp create_setup_intent(attrs) do
    form = [
      {"confirm", "true"},
      {"customer", Map.fetch!(attrs, :customer_id)},
      {"confirmation_token", Map.fetch!(attrs, :confirmation_token)},
      {"payment_method_types[]", "sepa_debit"},
      {"metadata[acceptance_attempt_id]", Map.fetch!(attrs, :attempt_id)}
    ]

    with :ok <- authorize_progression(attrs) do
      Operations.post_setup_intents(Map.new(form),
        idempotency_key: idempotency_key(attrs, "setup-intent")
      )
    end
  end

  defp ensure_setup_intent(_attrs, %{"payment_method_id" => payment_method_id} = state)
       when is_binary(payment_method_id) and payment_method_id != "" do
    {:ok,
     %{
       "id" => state["setup_intent_id"],
       "status" => "succeeded",
       "payment_method" => payment_method_id
     }}
  end

  defp ensure_setup_intent(_attrs, %{"setup_intent_id" => setup_intent_id})
       when is_binary(setup_intent_id) and setup_intent_id != "" do
    Operations.get_setup_intents_intent(setup_intent_id, %{})
  end

  defp ensure_setup_intent(attrs, _stripe_state), do: create_setup_intent(attrs)

  defp validate_setup_intent(%{"status" => status}) when status in ["succeeded", "processing"],
    do: :ok

  defp validate_setup_intent(%{"status" => status}), do: {:error, {:setup_intent_failed, status}}
  defp validate_setup_intent(_setup_intent), do: {:error, :invalid_setup_intent_response}

  defp payment_method_id(%{"payment_method" => payment_method}) when is_binary(payment_method),
    do: {:ok, payment_method}

  defp payment_method_id(%{"payment_method" => %{"id" => id}}) when is_binary(id), do: {:ok, id}
  defp payment_method_id(_setup_intent), do: {:error, :payment_method_missing}

  defp create_membership_subscriptions(customer_id, payment_method_id, plan, attrs) do
    stripe_state = Map.get(attrs, :stripe_state, %{})

    with {:ok, monthly} <-
           ensure_subscription(
             :monthly,
             customer_id,
             payment_method_id,
             plan.monthly_price_id,
             plan,
             stripe_state,
             attrs
           ),
         :ok <- report_subscription_progress(attrs, :monthly, monthly),
         :ok <- maybe_confirm_first_invoice(monthly, payment_method_id, plan, attrs),
         :ok <- report_progress(attrs, %{"monthly_confirmed" => true}),
         {:ok, annual} <-
           ensure_subscription(
             :annual,
             customer_id,
             payment_method_id,
             plan.annual_price_id,
             plan,
             stripe_state,
             attrs
           ),
         :ok <- report_subscription_progress(attrs, :annual, annual),
         :ok <- maybe_confirm_first_invoice(annual, payment_method_id, plan, attrs),
         :ok <- report_progress(attrs, %{"annual_confirmed" => true}) do
      :ok
    end
  end

  defp ensure_subscription(
         kind,
         customer_id,
         payment_method_id,
         price_id,
         promotion,
         state,
         attrs
       ) do
    key = "#{kind}_subscription_id"

    case Map.get(state, key) do
      id when is_binary(id) and id != "" ->
        Operations.get_subscriptions_subscription_exposed_id(id, %{},
          expand: ["latest_invoice.payments"]
        )

      _ ->
        create_subscription(kind, customer_id, payment_method_id, price_id, promotion, attrs)
    end
  end

  defp create_subscription(kind, customer_id, payment_method_id, price_id, promotion, attrs) do
    form =
      [
        {"customer", customer_id},
        {"items[0][price]", price_id},
        {"payment_behavior", "default_incomplete"},
        {"collection_method", "charge_automatically"},
        {"expand[]", "latest_invoice.payments"}
      ]
      |> maybe_add_payment_method(payment_method_id)
      |> add_billing_anchor(kind)
      |> maybe_add_discount(promotion)
      |> then(
        &[
          {"metadata[acceptance_attempt_id]", Map.fetch!(attrs, :attempt_id)},
          {"metadata[acceptance_kind]", Atom.to_string(kind)}
          | &1
        ]
      )

    with :ok <- authorize_progression(attrs) do
      Operations.post_subscriptions(Map.new(form),
        idempotency_key: idempotency_key(attrs, "subscription-#{kind}")
      )
    end
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

  defp maybe_add_payment_method(form, nil), do: form

  defp maybe_add_payment_method(form, payment_method_id),
    do: [{"default_payment_method", payment_method_id} | form]

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

  defp maybe_confirm_first_invoice(subscription, nil, %{requirement: :complimentary}, _attrs) do
    case latest_invoice(subscription) do
      %{"status" => "paid", "amount_due" => 0} ->
        :ok

      %{"status" => status, "amount_due" => amount_due} ->
        {:error, {:complimentary_invoice_unsettled, status, amount_due}}

      _ ->
        {:error, :complimentary_invoice_missing}
    end
  end

  defp maybe_confirm_first_invoice(_subscription, nil, _promotion, _attrs),
    do: {:error, :payment_method_required}

  defp maybe_confirm_first_invoice(subscription, payment_method_id, _promotion, attrs) do
    case payment_intent_id(subscription) do
      nil -> validate_paid_invoice(subscription)
      payment_intent_id -> progress_payment_intent(payment_intent_id, payment_method_id, attrs)
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

  defp progress_payment_intent(payment_intent_id, payment_method_id, attrs) do
    with :ok <- authorize_progression(attrs),
         {:ok, payment_intent} <-
           Operations.get_payment_intents_intent(payment_intent_id, %{}) do
      case payment_intent_outcome(payment_intent) do
        :confirm -> confirm_payment_intent(payment_intent_id, payment_method_id, attrs)
        outcome -> outcome
      end
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

    with :ok <- authorize_progression(attrs) do
      case Operations.post_payment_intents_intent_confirm(payment_intent_id, Map.new(form),
             idempotency_key: idempotency_key(attrs, "payment-intent-#{payment_intent_id}")
           ) do
        {:ok, payment_intent} -> payment_intent_outcome(payment_intent)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp payment_intent_outcome(%{"status" => "succeeded"}), do: :ok

  defp payment_intent_outcome(%{"id" => id, "status" => "processing"}) do
    {:pending,
     %{
       "payment_state" => "pending",
       "payment_intent_id" => id,
       "payment_intent_status" => "processing"
     }}
  end

  defp payment_intent_outcome(%{"id" => id, "status" => "requires_action"} = intent) do
    {:pending,
     %{
       "payment_state" => "needs_action",
       "payment_intent_id" => id,
       "payment_intent_status" => "requires_action",
       "payment_action_type" => get_in(intent, ["next_action", "type"])
     }}
  end

  defp payment_intent_outcome(%{"status" => "requires_confirmation"}), do: :confirm

  defp payment_intent_outcome(%{"id" => id, "status" => status})
       when status in ["requires_payment_method", "requires_capture", "canceled"] do
    {:pending,
     %{
       "payment_state" => "terminal",
       "payment_intent_id" => id,
       "payment_intent_status" => status
     }}
  end

  defp payment_intent_outcome(_payment_intent),
    do: {:error, :invalid_payment_intent_response}

  defp validate_paid_invoice(subscription) do
    case latest_invoice(subscription) do
      %{"status" => "paid"} -> :ok
      %{"status" => status} -> {:error, {:invoice_unsettled, status}}
      _ -> {:error, :invoice_payment_missing}
    end
  end

  defp create_credit_note(invoice_id, amount, attrs) do
    with :ok <- authorize_progression(attrs) do
      Operations.post_credit_notes(
        %{"invoice" => invoice_id, "amount" => Integer.to_string(amount)},
        idempotency_key: idempotency_key(attrs, "credit-note-#{invoice_id}")
      )
    end
  end

  defp payment_plan(%{payment_plan: plan}) when is_map(plan), do: {:ok, plan}
  defp payment_plan(attrs), do: Pricing.membership_payment_plan(Map.get(attrs, :coupon_code))

  defp authorize_progression(attrs) do
    case Map.get(attrs, :fence) do
      callback when is_function(callback, 0) -> callback.()
      _ -> :ok
    end
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
      callback when is_function(callback, 1) ->
        case callback.(progress) do
          :ok -> :ok
          {:error, reason} -> {:error, {:progress_persistence, reason}}
        end

      _ ->
        :ok
    end
  end

  defp reconcile_provider_progress(attrs) do
    state = Map.get(attrs, :stripe_state, %{})
    attempt_id = Map.fetch!(attrs, :attempt_id)
    customer_id = Map.fetch!(attrs, :customer_id)

    with {:ok, setup_intents} <-
           Operations.get_setup_intents(%{}, customer: customer_id, limit: 100),
         {:ok, subscriptions} <-
           Operations.get_subscriptions(%{},
             customer: customer_id,
             status: "all",
             limit: 100,
             expand: ["data.latest_invoice.payments"]
           ) do
      state =
        state
        |> merge_setup_intent_progress(setup_intents["data"] || [], attempt_id)
        |> merge_subscription_progress(subscriptions["data"] || [], attempt_id)

      case report_progress(attrs, state) do
        :ok -> {:ok, state}
        {:error, _reason} = error -> error
      end
    end
  end

  defp merge_setup_intent_progress(state, setup_intents, attempt_id) do
    case Enum.find(
           setup_intents,
           &(get_in(&1, ["metadata", "acceptance_attempt_id"]) == attempt_id)
         ) do
      nil ->
        state

      setup_intent ->
        state
        |> maybe_put("setup_intent_id", resource_id(setup_intent))
        |> maybe_put("payment_method_id", payment_method_value(setup_intent))
    end
  end

  defp merge_subscription_progress(state, subscriptions, attempt_id) do
    Enum.reduce(subscriptions, state, fn subscription, acc ->
      metadata = Map.get(subscription, "metadata", %{})

      if metadata["acceptance_attempt_id"] == attempt_id and
           metadata["acceptance_kind"] in ["monthly", "annual"] do
        kind = metadata["acceptance_kind"]

        acc
        |> maybe_put("#{kind}_subscription_id", resource_id(subscription))
        |> maybe_put("#{kind}_invoice_id", latest_invoice(subscription) |> resource_id())
        |> maybe_put("#{kind}_payment_intent_id", payment_intent_id(subscription))
      else
        acc
      end
    end)
  end

  defp payment_method_value(%{"payment_method" => id}) when is_binary(id), do: id
  defp payment_method_value(%{"payment_method" => %{"id" => id}}), do: id
  defp payment_method_value(_setup_intent), do: nil

  defp discover_subscription_ids(%{
         "customer_id" => customer_id,
         "acceptance_attempt_id" => attempt_id
       }) do
    case Operations.get_subscriptions(%{}, customer: customer_id, status: "all", limit: 100) do
      {:ok, %{"data" => subscriptions}} ->
        ids =
          subscriptions
          |> Enum.filter(&(get_in(&1, ["metadata", "acceptance_attempt_id"]) == attempt_id))
          |> Enum.map(&resource_id/1)
          |> Enum.reject(&is_nil/1)

        {:ok, ids}

      {:error, reason} ->
        {:error, {:subscription_cleanup_discovery_failed, reason}}
    end
  end

  defp discover_subscription_ids(_stripe_state), do: {:ok, []}

  defp find_customer_by_attempt(email, acceptance_attempt_id) do
    with {:ok, ids} <-
           list_customer_ids_for_attempt(email, acceptance_attempt_id, nil, MapSet.new()) do
      case MapSet.to_list(ids) do
        [] -> {:ok, nil}
        [id] -> {:ok, id}
        ids -> {:error, {:ambiguous_acceptance_customers, Enum.sort(ids)}}
      end
    end
  end

  defp list_customer_ids_for_attempt(email, acceptance_attempt_id, starting_after, ids) do
    opts =
      [email: email, limit: 100]
      |> maybe_add_starting_after(starting_after)

    case Operations.get_customers(%{}, opts) do
      {:ok, %{"data" => customers} = response} when is_list(customers) ->
        ids =
          Enum.reduce(customers, ids, fn customer, acc ->
            if get_in(customer, ["metadata", "acceptance_attempt_id"]) ==
                 acceptance_attempt_id do
              case resource_id(customer) do
                nil -> acc
                id -> MapSet.put(acc, id)
              end
            else
              acc
            end
          end)

        if response["has_more"] == true do
          case List.last(customers) |> resource_id() do
            nil -> {:error, :malformed_customer_page}
            cursor -> list_customer_ids_for_attempt(email, acceptance_attempt_id, cursor, ids)
          end
        else
          {:ok, ids}
        end

      {:ok, response} ->
        {:error, {:malformed_customer_list, response}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_add_starting_after(opts, nil), do: opts
  defp maybe_add_starting_after(opts, cursor), do: Keyword.put(opts, :starting_after, cursor)

  defp resource_id(%{"id" => id}) when is_binary(id), do: id
  defp resource_id(_resource), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
