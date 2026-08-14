defmodule Dhc.Onboarding.StripeAdapter do
  @moduledoc false

  @callback preview_membership(String.t() | nil) :: {:ok, map()} | {:error, term()}
  @callback payment_requirement(String.t() | nil) ::
              {:ok, :paid | :complimentary} | {:error, term()}
  @callback create_customer(map()) :: {:ok, String.t()} | {:error, term()}
  @callback provision_membership(map()) :: {:ok, map()} | {:error, term()}
  @callback cancel_membership(map()) :: :ok | {:error, term()}
  @callback retryable_failure?(term()) :: boolean()
end
