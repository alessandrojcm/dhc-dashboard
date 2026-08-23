defmodule Dhc.Onboarding.StripeAdapter do
  @moduledoc false

  @type discount_reference ::
          String.t() | {:coupon, String.t(), [:monthly | :annual]} | nil

  @callback preview_membership(discount_reference()) :: {:ok, map()} | {:error, term()}
  @callback prepare_payment(discount_reference()) :: {:ok, map()} | {:error, term()}
  @callback create_customer(map()) :: {:ok, String.t()} | {:error, term()}
  @callback provision_membership(map()) ::
              {:ok, map()} | {:pending, map()} | {:error, term()}
  @callback cancel_membership(map()) :: :ok | {:error, term()}
  @callback retryable_failure?(term()) :: boolean()
end
