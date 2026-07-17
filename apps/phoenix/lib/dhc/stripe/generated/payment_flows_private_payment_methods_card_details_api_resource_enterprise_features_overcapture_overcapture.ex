defmodule Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsCardDetailsApiResourceEnterpriseFeaturesOvercaptureOvercapture do
  @moduledoc """
  Provides struct and type for a PaymentFlowsPrivatePaymentMethodsCardDetailsApiResourceEnterpriseFeaturesOvercaptureOvercapture
  """

  @type t :: %__MODULE__{maximum_amount_capturable: integer, status: String.t()}

  defstruct [:maximum_amount_capturable, :status]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [maximum_amount_capturable: :integer, status: {:enum, ["available", "unavailable"]}]
  end
end
