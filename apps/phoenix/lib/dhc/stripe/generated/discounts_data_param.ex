defmodule Dhc.Stripe.DiscountsDataParam do
  @moduledoc """
  Provides struct and types for a DiscountsDataParam
  """

  @type t :: %__MODULE__{
          coupon: String.t() | nil,
          discount: String.t() | nil,
          promotion_code: String.t() | nil
        }

  defstruct [:coupon, :discount, :promotion_code]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [coupon: :string, discount: :string, promotion_code: :string]
  end
end
