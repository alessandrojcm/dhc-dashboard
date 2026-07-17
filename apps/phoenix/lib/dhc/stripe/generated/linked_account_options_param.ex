defmodule Dhc.Stripe.LinkedAccountOptionsParam do
  @moduledoc """
  Provides struct and types for a LinkedAccountOptionsParam
  """

  @type t :: %__MODULE__{
          filters: Dhc.Stripe.LinkedAccountOptionsFiltersParam.t() | nil,
          permissions: [String.t()] | nil,
          prefetch: [String.t()] | nil,
          return_url: String.t() | nil
        }

  defstruct [:filters, :permissions, :prefetch, :return_url]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      filters: {Dhc.Stripe.LinkedAccountOptionsFiltersParam, :t},
      permissions: [enum: ["balances", "ownership", "payment_method", "transactions"]],
      prefetch: [enum: ["balances", "ownership", "transactions"]],
      return_url: :string
    ]
  end
end
