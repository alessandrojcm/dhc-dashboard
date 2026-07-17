defmodule Dhc.Stripe.MandatePix do
  @moduledoc """
  Provides struct and type for a MandatePix
  """

  @type t :: %__MODULE__{
          amount_includes_iof: String.t() | nil,
          amount_type: String.t() | nil,
          end_date: String.t() | nil,
          payment_schedule: String.t() | nil,
          reference: String.t() | nil,
          start_date: String.t() | nil
        }

  defstruct [
    :amount_includes_iof,
    :amount_type,
    :end_date,
    :payment_schedule,
    :reference,
    :start_date
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount_includes_iof: {:enum, ["always", "never"]},
      amount_type: {:enum, ["fixed", "maximum"]},
      end_date: :string,
      payment_schedule: {:enum, ["halfyearly", "monthly", "quarterly", "weekly", "yearly"]},
      reference: :string,
      start_date: :string
    ]
  end
end
