defmodule Dhc.Stripe.DisputePaymentMethodDetailsCard do
  @moduledoc """
  Provides struct and type for a DisputePaymentMethodDetailsCard
  """

  @type t :: %__MODULE__{
          brand: String.t(),
          case_type: String.t(),
          network_reason_code: String.t() | nil
        }

  defstruct [:brand, :case_type, :network_reason_code]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      brand: :string,
      case_type: {:enum, ["block", "chargeback", "compliance", "inquiry", "resolution"]},
      network_reason_code: :string
    ]
  end
end
