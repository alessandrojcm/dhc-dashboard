defmodule Dhc.Stripe.SetupIntentMandateOptionsParam do
  @moduledoc """
  Provides struct and type for a SetupIntentMandateOptionsParam
  """

  @type t :: %__MODULE__{
          amount: integer,
          amount_type: String.t(),
          currency: String.t(),
          description: String.t() | nil,
          end_date: integer | nil,
          interval: String.t(),
          interval_count: integer | nil,
          reference: String.t(),
          start_date: integer,
          supported_types: [String.t()] | nil
        }

  defstruct [
    :amount,
    :amount_type,
    :currency,
    :description,
    :end_date,
    :interval,
    :interval_count,
    :reference,
    :start_date,
    :supported_types
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      amount_type: {:enum, ["fixed", "maximum"]},
      currency: {:string, "currency"},
      description: :string,
      end_date: {:integer, "unix-time"},
      interval: {:enum, ["day", "month", "sporadic", "week", "year"]},
      interval_count: :integer,
      reference: :string,
      start_date: {:integer, "unix-time"},
      supported_types: [const: "india"]
    ]
  end
end
