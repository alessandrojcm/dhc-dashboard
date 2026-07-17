defmodule Dhc.Stripe.IssuingCardShippingAddressValidation do
  @moduledoc """
  Provides struct and type for a IssuingCardShippingAddressValidation
  """

  @type t :: %__MODULE__{
          mode: String.t(),
          normalized_address: Dhc.Stripe.Address.t() | nil,
          result: String.t() | nil
        }

  defstruct [:mode, :normalized_address, :result]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      mode: {:enum, ["disabled", "normalization_only", "validation_and_normalization"]},
      normalized_address: {Dhc.Stripe.Address, :t},
      result: {:enum, ["indeterminate", "likely_deliverable", "likely_undeliverable"]}
    ]
  end
end
