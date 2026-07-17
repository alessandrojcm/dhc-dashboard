defmodule Dhc.Stripe.Mandate do
  @moduledoc """
  Provides struct and type for a Mandate
  """

  @type t :: %__MODULE__{
          customer_acceptance: Dhc.Stripe.CustomerAcceptance.t(),
          id: String.t(),
          livemode: boolean,
          multi_use: Dhc.Stripe.MandateMultiUse.t() | nil,
          object: String.t(),
          on_behalf_of: String.t() | nil,
          payment_method: Dhc.Stripe.PaymentMethod.t() | String.t(),
          payment_method_details: Dhc.Stripe.MandatePaymentMethodDetails.t(),
          single_use: Dhc.Stripe.MandateSingleUse.t() | nil,
          status: String.t(),
          type: String.t()
        }

  defstruct [
    :customer_acceptance,
    :id,
    :livemode,
    :multi_use,
    :object,
    :on_behalf_of,
    :payment_method,
    :payment_method_details,
    :single_use,
    :status,
    :type
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      customer_acceptance: {Dhc.Stripe.CustomerAcceptance, :t},
      id: :string,
      livemode: :boolean,
      multi_use: {Dhc.Stripe.MandateMultiUse, :t},
      object: {:const, "mandate"},
      on_behalf_of: :string,
      payment_method: {:union, [:string, {Dhc.Stripe.PaymentMethod, :t}]},
      payment_method_details: {Dhc.Stripe.MandatePaymentMethodDetails, :t},
      single_use: {Dhc.Stripe.MandateSingleUse, :t},
      status: {:enum, ["active", "inactive", "pending"]},
      type: {:enum, ["multi_use", "single_use"]}
    ]
  end
end
