defmodule Dhc.StripeWebhooks do
  @moduledoc """
  Routes a verified Stripe webhook event to the domain reconcile functions
  that own its consequences.

  `Dhc.StripeWebhooks.Worker` calls `process_event/1` after deserializing the
  event from Oban job args. This module holds no domain logic: the routing
  table below (`routes/0`) is the **only** list of Stripe event types the app
  handles, `allowed_event_types/0` is built from its keys, and every event type
  outside it is logged and acknowledged with `:ok`.

  ## Targets

  A target is a plain tag; `run_target/3` is the one place that turns a tag
  into a call.

    * `:acceptance` — `Dhc.Onboarding.Acceptance.reconcile_stripe_event/1`
      brings forward Invitation Acceptance recovery for the event's Stripe
      customer.
    * `{:stripe_sync, :customer_required}` / `{:stripe_sync, :customer_optional}`
      — `Dhc.StripeSync.run_sync/1` re-syncs Membership for the event's Stripe
      customer (ADR 0008: `StripeSync` reconciles Membership). A subscription
      event without a customer is an error (`:missing_customer_id`); an invoice
      or PaymentIntent event without one is a no-op.
    * `:workshop_refund` — `Dhc.Workshops.apply_stripe_refund_event/1` applies
      a Stripe Refund object to the Workshop Refund it belongs to.
    * `{:beginners_intake, :complete_payment}` /
      `{:beginners_intake, :release_payment}` — the Beginners' Workshop
      boundary (`Dhc.BeginnersWorkshops.execute(:stripe, …)`, ALE-381)
      completes or releases the Seat Hold whose Checkout Session the event
      carries. A session that is not an Intake payment (a Workshop guest
      checkout) is acknowledged without effect.

  Targets run in table order; the first error stops the event and is returned.

  ## Contract: every target is idempotent

  The worker retries the **whole event** under Oban `max_attempts: 3`, so when
  one target fails, the targets before it run again on the next attempt, and
  Stripe may redeliver an event after its 24-hour uniqueness window. A target
  added to this table must therefore be safe to run any number of times for
  the same event.
  """

  require Logger

  @acceptance :acceptance
  @membership_required {:stripe_sync, :customer_required}
  @membership_optional {:stripe_sync, :customer_optional}
  @workshop_refund :workshop_refund
  @intake_complete {:beginners_intake, :complete_payment}
  @intake_release {:beginners_intake, :release_payment}

  # The routing table. Every target must be idempotent (see moduledoc).
  #
  # Replay window: `Dhc.StripeWebhooks.Worker` is unique on the event id for
  # 24 hours across ALL job states (`states: :all`), including `discarded`. A
  # job discarded after its 3 attempts therefore cannot be replayed by
  # re-sending the same Stripe event (dashboard "Resend" or a Stripe retry)
  # within those 24 hours: the insert is deduplicated and nothing runs. Fix the
  # cause, then retry the discarded job itself (`Oban.retry_job/1`) or wait out
  # the window.
  @route_groups [
    {~w(
       customer.subscription.created
       customer.subscription.updated
       customer.subscription.deleted
       customer.subscription.paused
       customer.subscription.resumed
       customer.subscription.pending_update_applied
       customer.subscription.pending_update_expired
       customer.subscription.trial_will_end
     ), [@acceptance, @membership_required]},
    {~w(
       invoice.paid
       invoice.payment_failed
       invoice.payment_action_required
       invoice.upcoming
       invoice.marked_uncollectible
       invoice.payment_succeeded
     ), [@acceptance, @membership_optional]},
    {~w(
       payment_intent.succeeded
       payment_intent.payment_failed
       payment_intent.canceled
     ), [@acceptance, @membership_optional]},
    {~w(refund.created refund.updated refund.failed), [@workshop_refund]},
    {~w(checkout.session.completed), [@intake_complete]},
    {~w(checkout.session.expired), [@intake_release]}
  ]

  @routes for {types, targets} <- @route_groups, type <- types, into: %{}, do: {type, targets}

  @typedoc "A tag naming the domain reconcile function an event is routed to."
  @type target ::
          :acceptance
          | :workshop_refund
          | {:beginners_intake, :complete_payment | :release_payment}
          | {:stripe_sync, :customer_required | :customer_optional}

  @doc """
  Returns the routing table: each handled event type and the targets it calls,
  in call order.
  """
  @spec routes() :: %{String.t() => [target()]}
  def routes, do: @routes

  @doc """
  Returns the event types this module routes — exactly the keys of `routes/0`.
  """
  @spec allowed_event_types() :: [String.t()]
  def allowed_event_types, do: Map.keys(@routes)

  @doc """
  Processes a Stripe webhook event by running its routed targets.

  Returns `:ok` on success, `{:error, reason}` on failure. Unknown event types
  are acknowledged with `:ok`.

  The `event` map is expected to have:
    * `"type"` — the Stripe event type string
    * `"data"` — map with `"object"` containing the event payload
  """
  @spec process_event(map()) :: :ok | {:error, term()}
  def process_event(%{"type" => event_type, "data" => %{"object" => object}} = event) do
    case Map.fetch(@routes, event_type) do
      {:ok, targets} ->
        Logger.info("[stripe-webhooks] Routing event",
          event_type: event_type,
          event_id: Map.get(event, "id", "unknown")
        )

        run_targets(targets, event_type, object)

      :error ->
        Logger.info("[stripe-webhooks] Unhandled event type, acknowledging",
          event_type: event_type,
          event_id: Map.get(event, "id", "unknown")
        )

        :ok
    end
  end

  def process_event(%{"type" => event_type}) do
    Logger.warning("[stripe-webhooks] Event missing data.object",
      event_type: event_type
    )

    {:error, :missing_data_object}
  end

  def process_event(event) do
    Logger.warning("[stripe-webhooks] Malformed event: #{inspect(event)}")
    {:error, :malformed_event}
  end

  defp run_targets(targets, event_type, object) do
    Enum.reduce_while(targets, :ok, fn target, :ok ->
      case run_target(target, event_type, object) do
        :ok ->
          {:cont, :ok}

        {:error, reason} = error ->
          Logger.error("[stripe-webhooks] Event target #{inspect(target)} failed",
            event_type: event_type,
            reason: inspect(reason)
          )

          {:halt, error}
      end
    end)
  end

  defp run_target(@acceptance, _event_type, object),
    do: Dhc.Onboarding.Acceptance.reconcile_stripe_event(object)

  defp run_target(@workshop_refund, _event_type, object),
    do: Dhc.Workshops.apply_stripe_refund_event(object)

  defp run_target({:beginners_intake, command}, _event_type, object) do
    case Dhc.BeginnersWorkshops.execute(:stripe, {command, object}) do
      {:ok, _outcome} -> :ok
      {:error, reason} -> {:error, {:beginners_intake, reason}}
    end
  end

  defp run_target({:stripe_sync, customer_policy}, event_type, object) do
    case {customer_id(object), customer_policy} do
      {nil, :customer_required} ->
        Logger.warning("[stripe-webhooks] No customer ID on event",
          event_type: event_type,
          object_id: Map.get(object, "id", "unknown")
        )

        {:error, :missing_customer_id}

      {nil, :customer_optional} ->
        Logger.info("[stripe-webhooks] Event without customer, skipping Membership sync",
          event_type: event_type
        )

        :ok

      {customer_id, _policy} ->
        case Dhc.StripeSync.run_sync([customer_id]) do
          {:ok, _summary} -> :ok
          {:error, reason} -> {:error, {:sync_failed, reason}}
        end
    end
  end

  defp customer_id(%{"customer" => id}) when is_binary(id) and id != "", do: id
  defp customer_id(%{"customer" => %{"id" => id}}) when is_binary(id) and id != "", do: id
  defp customer_id(_object), do: nil
end
