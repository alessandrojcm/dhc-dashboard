defmodule Dhc.Workshops.StripeAdapter do
  @moduledoc false

  @callback create_payment_intent(map()) :: {:ok, map()} | {:error, term()}
  @callback retrieve_payment_intent(String.t()) :: {:ok, map()} | {:error, term()}
  @callback create_checkout_session(map()) :: {:ok, map()} | {:error, term()}
  @callback retrieve_checkout_session(String.t()) :: {:ok, map()} | {:error, term()}
  @callback update_payment_intent(String.t(), map()) :: :ok | {:error, term()}
  @callback create_refund(map()) :: {:ok, map()} | {:error, term()}
  @callback retrieve_refund(String.t()) :: {:ok, map()} | {:error, term()}
end
