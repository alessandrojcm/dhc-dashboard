defmodule Dhc.Stripe.MethodParams do
  @moduledoc """
  Provides struct and type for a MethodParams
  """

  @type t :: %__MODULE__{
          delivery_estimate: Dhc.Stripe.DeliveryEstimate.t() | nil,
          display_name: String.t(),
          fixed_amount: Dhc.Stripe.FixedAmount.t() | nil,
          metadata: map | nil,
          tax_behavior: String.t() | nil,
          tax_code: String.t() | nil,
          type: String.t() | nil
        }

  defstruct [
    :delivery_estimate,
    :display_name,
    :fixed_amount,
    :metadata,
    :tax_behavior,
    :tax_code,
    :type
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      delivery_estimate: {Dhc.Stripe.DeliveryEstimate, :t},
      display_name: :string,
      fixed_amount: {Dhc.Stripe.FixedAmount, :t},
      metadata: :map,
      tax_behavior: {:enum, ["exclusive", "inclusive", "unspecified"]},
      tax_code: :string,
      type: {:const, "fixed_amount"}
    ]
  end
end
