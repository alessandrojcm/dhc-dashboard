defmodule Dhc.Stripe.Processor do
  @moduledoc """
  Custom OpenAPI processor that acts as an allowlist for Stripe operations.

  Stripe's spec has hundreds of endpoints. We only generate the ones we use.
  Add new operation IDs to @allowed_operations as needed.

  New endpoints are added by:
  1. Adding the operation ID to @allowed_operations below
  2. Running `mise run stripe-gen` to regenerate

  Because oapi_generator is operation-first, schemas not referenced by any
  allowed operation are automatically excluded from the output.
  """

  use OpenAPI.Processor

  # ── Allowlist ────────────────────────────────────────────────────────
  # Only these operation IDs will be generated. Everything else is ignored.
  # Add new operations here as the Phoenix app needs more Stripe endpoints.

  @allowed_operations MapSet.new([
    # Subscriptions
    "GetSubscriptions",
    "PostSubscriptions",
    "GetSubscriptionsSubscriptionExposedId",
    "PostSubscriptionsSubscriptionExposedId",
    "DeleteSubscriptionsSubscriptionExposedId",
    "PostSubscriptionsSubscriptionResume",
    # Prices
    "GetPrices",
    "GetPricesPrice",
    "PostPrices",
    # Customers (needed for sync worker)
    "GetCustomers",
    "GetCustomersCustomer",
    "PostCustomers"
  ])

  # ── Operation filtering ──────────────────────────────────────────────

  @impl OpenAPI.Processor
  def ignore_operation?(_state, operation_spec) do
    operation_id = Map.get(operation_spec, :operation_id) || Map.get(operation_spec, "operationId")

    case operation_id do
      nil -> true
      id -> not MapSet.member?(@allowed_operations, id)
    end
  end

  # Fall through to default implementation for all other callbacks
end