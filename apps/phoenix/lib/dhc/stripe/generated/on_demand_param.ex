defmodule Dhc.Stripe.OnDemandParam do
  @moduledoc """
  Provides struct and types for a OnDemandParam
  """

  @type t :: %__MODULE__{
          average_amount: integer | nil,
          maximum_amount: integer | nil,
          minimum_amount: integer | nil,
          purchase_interval: String.t() | nil,
          purchase_interval_count: integer | nil
        }

  defstruct [
    :average_amount,
    :maximum_amount,
    :minimum_amount,
    :purchase_interval,
    :purchase_interval_count
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      average_amount: :integer,
      maximum_amount: :integer,
      minimum_amount: :integer,
      purchase_interval: {:enum, ["day", "month", "week", "year"]},
      purchase_interval_count: :integer
    ]
  end
end
