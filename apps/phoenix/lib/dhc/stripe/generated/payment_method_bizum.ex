defmodule Dhc.Stripe.PaymentMethodBizum do
  @moduledoc """
  Provides struct and type for a PaymentMethodBizum
  """

  @type t :: %__MODULE__{buyer_id: String.t() | nil}

  defstruct [:buyer_id]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [buyer_id: :string]
  end
end
