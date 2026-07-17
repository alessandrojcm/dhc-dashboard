defmodule Dhc.Stripe.PromotionCodesResourceRestrictions do
  @moduledoc """
  Provides struct and type for a PromotionCodesResourceRestrictions
  """

  @type t :: %__MODULE__{
          currency_options: map | nil,
          first_time_transaction: boolean,
          minimum_amount: integer | nil,
          minimum_amount_currency: String.t() | nil
        }

  defstruct [
    :currency_options,
    :first_time_transaction,
    :minimum_amount,
    :minimum_amount_currency
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      currency_options: :map,
      first_time_transaction: :boolean,
      minimum_amount: :integer,
      minimum_amount_currency: :string
    ]
  end
end
