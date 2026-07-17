defmodule Dhc.Stripe.PaymentMethodCashapp do
  @moduledoc """
  Provides struct and type for a PaymentMethodCashapp
  """

  @type t :: %__MODULE__{buyer_id: String.t() | nil, cashtag: String.t() | nil}

  defstruct [:buyer_id, :cashtag]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [buyer_id: :string, cashtag: :string]
  end
end
