defmodule Dhc.Stripe.PaypalSellerProtection do
  @moduledoc """
  Provides struct and type for a PaypalSellerProtection
  """

  @type t :: %__MODULE__{dispute_categories: [String.t()] | nil, status: String.t()}

  defstruct [:dispute_categories, :status]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      dispute_categories: [enum: ["fraudulent", "product_not_received"]],
      status: {:enum, ["eligible", "not_eligible", "partially_eligible"]}
    ]
  end
end
