defmodule Dhc.Stripe.PaymentMethodCardChecks do
  @moduledoc """
  Provides struct and type for a PaymentMethodCardChecks
  """

  @type t :: %__MODULE__{
          address_line1_check: String.t() | nil,
          address_postal_code_check: String.t() | nil,
          cvc_check: String.t() | nil
        }

  defstruct [:address_line1_check, :address_postal_code_check, :cvc_check]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [address_line1_check: :string, address_postal_code_check: :string, cvc_check: :string]
  end
end
