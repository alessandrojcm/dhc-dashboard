defmodule Dhc.Stripe.PaymentMethodNaverPay do
  @moduledoc """
  Provides struct and type for a PaymentMethodNaverPay
  """

  @type t :: %__MODULE__{buyer_id: String.t() | nil, funding: String.t()}

  defstruct [:buyer_id, :funding]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [buyer_id: :string, funding: {:enum, ["card", "points"]}]
  end
end
