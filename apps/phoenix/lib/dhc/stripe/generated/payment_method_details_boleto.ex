defmodule Dhc.Stripe.PaymentMethodDetailsBoleto do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsBoleto
  """

  @type t :: %__MODULE__{tax_id: String.t()}

  defstruct [:tax_id]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [tax_id: :string]
  end
end
