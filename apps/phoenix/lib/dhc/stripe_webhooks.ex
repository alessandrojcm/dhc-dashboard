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
  subscription-state synchronization. Charge events no longer mutate
  registrations directly — the dead `ch_*` handlers
  (`confirm_workshop_registration` / `cancel_expired_workshop_registration`)
  were removed in the ALE-193 code release because they matched charge ids
  against a column that only holds `pi_*` / `cs_*` ids. Registration
  confirmation is driven by `payment_intent.*` / checkout completion.
  """

  require Logger

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
    "payment_intent.canceled",
    "refund.created",
    "refund.updated",
    "refund.failed"
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

      event_type in ["refund.created", "refund.updated", "refund.failed"] ->
        Dhc.Workshops.Refund.apply_provider_update(object)

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
      {_workshop_id, _registration_data} ->
        # The ch_* charge-event → registration handlers were dead: they
        # matched charge ids against stripe_checkout_session_id, a column
        # that only holds pi_/cs_ ids. Real charge ids never matched, so
        # both branches always no-op'd. Registration confirmation is driven
        # by payment_intent.* / checkout completion, not charge.* events.
        # Fall through to the customer sync, same as the no-metadata branch.
        maybe_sync_customer(object)

      nil ->
        # Not a workshop charge — sync customer if present
        maybe_sync_customer(object)
    end
  end

  defp handle_charge_expired(object) do
    case extract_workshop_metadata(object) do
      {_workshop_id, _registration_data} ->
        # See handle_charge_succeeded/1: the ch_ handler was dead. No-op.
        :ok

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
