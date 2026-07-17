defmodule Dhc.Stripe.SetupAttemptPaymentMethodDetailsCardWallet do
  @moduledoc """
  Provides struct and type for a SetupAttemptPaymentMethodDetailsCardWallet
  """

  @type t :: %__MODULE__{apple_pay: map | nil, google_pay: map | nil, type: String.t()}

  defstruct [:apple_pay, :google_pay, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [apple_pay: :map, google_pay: :map, type: {:enum, ["apple_pay", "google_pay", "link"]}]
  end
end
