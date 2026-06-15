defmodule Dhc.StripeWebhooks do
  @moduledoc """
  Context module for Stripe webhook event processing.

  Provides the domain logic for handling each Stripe webhook event type.
  The `Dhc.StripeWebhooks.Worker` delegates to this module after
  deserializing the event from Oban job args.

  This separation keeps the worker focused on job orchestration
  while the context handles domain logic and database updates.

  ## Supported event types

    * **Charge events** — `charge.succeeded`, `charge.expired`, `charge.refunded`
    * **Subscription events** — `customer.subscription.created`,
      `customer.subscription.updated`, `customer.subscription.deleted`,
      `customer.subscription.paused`, `customer.subscription.resumed`
    * **Customer events** — handled implicitly via subscription events
      (the `customer` field on subscription objects drives the sync)

  ## Architecture

  Event handlers in this module delegate to `Dhc.StripeSync` for
  subscription-state synchronization and perform direct database
  updates for charge/workshop-related events, following the same
  patterns established in the Deno edge function.
  """

  import Ecto.Query

  require Logger

  alias Dhc.Repo

  @allowed_event_types [
    "charge.succeeded",
    "charge.expired",
    "charge.refunded",
    "customer.subscription.created",
    "customer.subscription.updated",
    "customer.subscription.deleted",
    "customer.subscription.paused",
    "customer.subscription.resumed",
    "customer.subscription.pending_update_applied",
    "customer.subscription.pending_update_expired",
    "customer.subscription.trial_will_end",
    "invoice.paid",
    "invoice.payment_failed",
    "invoice.payment_action_required",
    "invoice.upcoming",
    "invoice.marked_uncollectible",
    "invoice.payment_succeeded",
    "payment_intent.succeeded",
    "payment_intent.payment_failed",
    "payment_intent.canceled"
  ]

  @doc """
  Returns the list of event types this module handles (or acknowledges).
  """
  @spec allowed_event_types() :: [String.t()]
  def allowed_event_types, do: @allowed_event_types

  @doc """
  Processes a Stripe webhook event.

  Returns `:ok` on success, `{:error, reason}` on failure.
  Unknown event types are acknowledged with `:ok` (idempotent no-op).

  The `event` map is expected to have:
    * `"type"` — the Stripe event type string
    * `"data"` — map with `"object"` containing the event payload
  """
  @spec process_event(map()) :: :ok | {:error, term()}
  def process_event(%{"type" => event_type, "data" => %{"object" => object}}) do
    Logger.info("[stripe-webhooks] Processing event",
      event_type: event_type,
      event_id: Map.get(object, "id", "unknown")
    )

    cond do
      event_type in [
        "customer.subscription.created",
        "customer.subscription.updated",
        "customer.subscription.deleted",
        "customer.subscription.paused",
        "customer.subscription.resumed",
        "customer.subscription.pending_update_applied",
        "customer.subscription.pending_update_expired",
        "customer.subscription.trial_will_end"
      ] ->
        handle_subscription_event(event_type, object)

      event_type == "charge.succeeded" ->
        handle_charge_succeeded(object)

      event_type == "charge.expired" ->
        handle_charge_expired(object)

      event_type == "charge.refunded" ->
        handle_charge_refunded(object)

      event_type in [
        "invoice.paid",
        "invoice.payment_failed",
        "invoice.payment_action_required",
        "invoice.upcoming",
        "invoice.marked_uncollectible",
        "invoice.payment_succeeded"
      ] ->
        # Invoice events also trigger subscription sync if a customer is present
        handle_invoice_event(event_type, object)

      event_type in [
        "payment_intent.succeeded",
        "payment_intent.payment_failed",
        "payment_intent.canceled"
      ] ->
        # Payment intent events — acknowledge for now, may trigger sync
        handle_payment_intent_event(event_type, object)

      true ->
        Logger.info("[stripe-webhooks] Unhandled event type, acknowledging",
          event_type: event_type
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

  # ── Subscription events ──────────────────────────────────────────────

  defp handle_subscription_event(event_type, object) do
    customer_id = extract_customer_id(object)

    if is_nil(customer_id) or customer_id == "" do
      Logger.warning("[stripe-webhooks] No customer ID on subscription event",
        event_type: event_type,
        object_id: Map.get(object, "id", "unknown")
      )

      {:error, :missing_customer_id}
    else
      Logger.info("[stripe-webhooks] Syncing subscription state",
        event_type: event_type,
        customer_id: customer_id
      )

      case Dhc.StripeSync.run_sync([customer_id]) do
        {:ok, _summary} ->
          Logger.info("[stripe-webhooks] Subscription sync complete",
            event_type: event_type,
            customer_id: customer_id
          )

          :ok

        {:error, reason} ->
          Logger.error("[stripe-webhooks] Subscription sync failed",
            event_type: event_type,
            customer_id: customer_id,
            reason: inspect(reason)
          )

          {:error, {:sync_failed, reason}}
      end
    end
  end

  # ── Charge events ────────────────────────────────────────────────────

  defp handle_charge_succeeded(object) do
    case extract_workshop_metadata(object) do
      {_workshop_id, _registration_data} = metadata ->
        confirm_workshop_registration(object, metadata)

      nil ->
        # Not a workshop charge — still sync customer if present
        maybe_sync_customer(object)
    end
  end

  defp handle_charge_expired(object) do
    case extract_workshop_metadata(object) do
      {_workshop_id, _registration_data} ->
        cancel_expired_workshop_registration(object)

      nil ->
        :ok
    end
  end

  defp handle_charge_refunded(object) do
    # Refund processing is more complex — we need to look up refunds from Stripe
    # For now, update based on what we have in the charge object
    charge_id = Map.get(object, "id", "unknown")

    # Sync the refund state using the Stripe API to get proper refund records
    # This is deferred to the Stripe sync worker which has API access
    Logger.info("[stripe-webhooks] Charge refunded, syncing customer state",
      charge_id: charge_id
    )

    maybe_sync_customer(object)
  end

  # ── Invoice events ────────────────────────────────────────────────────

  defp handle_invoice_event(event_type, object) do
    customer_id = extract_customer_id(object)

    if customer_id do
      Logger.info("[stripe-webhooks] Invoice event, syncing customer",
        event_type: event_type,
        customer_id: customer_id
      )

      case Dhc.StripeSync.run_sync([customer_id]) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, {:sync_failed, reason}}
      end
    else
      Logger.info("[stripe-webhooks] Invoice event without customer, skipping sync",
        event_type: event_type
      )

      :ok
    end
  end

  # ── Payment intent events ────────────────────────────────────────────

  defp handle_payment_intent_event(event_type, object) do
    customer_id = extract_customer_id(object)

    if customer_id do
      Logger.info("[stripe-webhooks] Payment intent event, syncing customer",
        event_type: event_type,
        customer_id: customer_id
      )

      case Dhc.StripeSync.run_sync([customer_id]) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, {:sync_failed, reason}}
      end
    else
      Logger.info("[stripe-webhooks] Payment intent event without customer, skipping",
        event_type: event_type
      )

      :ok
    end
  end

  # ── Workshop registration helpers ────────────────────────────────────

  defp extract_workshop_metadata(%{"metadata" => metadata}) do
    workshop_id = Map.get(metadata, "workshop_id")
    registration_data = Map.get(metadata, "registration_data")

    if workshop_id && workshop_id != "" do
      {workshop_id, registration_data}
    else
      nil
    end
  end

  defp extract_workshop_metadata(_object), do: nil

  defp confirm_workshop_registration(
         %{"id" => charge_id, "amount" => amount},
         {workshop_id, _registration_data_raw}
       ) do
    Logger.info("[stripe-webhooks] Confirming workshop registration",
      charge_id: charge_id,
      workshop_id: workshop_id,
      amount: amount
    )

    try do
      # Look up existing registration by charge_id (stored as checkout session ID)
      # In the Deno function this was by checkout session ID, but charge events
      # have the charge ID on the object.
      # Update status to confirmed and set confirmed_at
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      result =
        from(r in "club_activity_registrations",
          where: r.stripe_checkout_session_id == ^charge_id and r.status == ^"pending"
        )
        |> Repo.update_all(set: [status: "confirmed", confirmed_at: now])

      case result do
        {0, _} ->
          Logger.info(
            "[stripe-webhooks] No pending registration found for charge, may already be confirmed",
            charge_id: charge_id,
            workshop_id: workshop_id
          )

          :ok

        {count, _} ->
          Logger.info("[stripe-webhooks] Confirmed workshop registration(s)",
            charge_id: charge_id,
            workshop_id: workshop_id,
            count: count
          )

          :ok
      end
    rescue
      e ->
        Logger.error("[stripe-webhooks] Failed to confirm workshop registration",
          charge_id: charge_id,
          workshop_id: workshop_id,
          error: inspect(e)
        )

        Sentry.capture_exception(e,
          stacktrace: __STACKTRACE__,
          extra: %{charge_id: charge_id, workshop_id: workshop_id}
        )

        {:error, {:db_error, e}}
    end
  end

  defp cancel_expired_workshop_registration(%{"id" => charge_id}) do
    Logger.info("[stripe-webhooks] Cancelling expired workshop registration",
      charge_id: charge_id
    )

    try do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      result =
        from(r in "club_activity_registrations",
          where: r.stripe_checkout_session_id == ^charge_id and r.status == ^"pending"
        )
        |> Repo.update_all(set: [status: "cancelled", cancelled_at: now])

      case result do
        {0, _} ->
          Logger.info("[stripe-webhooks] No pending registration found for expired charge",
            charge_id: charge_id
          )

          :ok

        {count, _} ->
          Logger.info("[stripe-webhooks] Cancelled expired workshop registration(s)",
            charge_id: charge_id,
            count: count
          )

          :ok
      end
    rescue
      e ->
        Logger.error("[stripe-webhooks] Failed to cancel expired registration",
          charge_id: charge_id,
          error: inspect(e)
        )

        Sentry.capture_exception(e,
          stacktrace: __STACKTRACE__,
          extra: %{charge_id: charge_id}
        )

        {:error, {:db_error, e}}
    end
  end

  # ── Customer sync helpers ────────────────────────────────────────────

  defp maybe_sync_customer(object) do
    customer_id = extract_customer_id(object)

    if customer_id && customer_id != "" do
      case Dhc.StripeSync.run_sync([customer_id]) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, {:sync_failed, reason}}
      end
    else
      :ok
    end
  end

  # ── Utility ──────────────────────────────────────────────────────────

  defp extract_customer_id(%{"customer" => customer_id}) when is_binary(customer_id) do
    customer_id
  end

  defp extract_customer_id(%{"customer" => %{"id" => id}}), do: id

  # Some objects nest customer differently (e.g., invoices)
  defp extract_customer_id(object) do
    # Try common paths
    case object do
      %{"customer" => customer_id} when is_binary(customer_id) -> customer_id
      %{"customer" => %{"id" => id}} -> id
      _ -> nil
    end
  end
end
