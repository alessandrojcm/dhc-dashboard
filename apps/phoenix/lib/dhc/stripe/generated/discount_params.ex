defmodule Dhc.Stripe.DiscountParams do
  @moduledoc """
  Provides struct and type for a DiscountParams
  """

  @type t :: %__MODULE__{coupon: String.t() | nil, promotion_code: String.t() | nil}

  defstruct [:coupon, :promotion_code]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [coupon: :string, promotion_code: :string]
  end
end
