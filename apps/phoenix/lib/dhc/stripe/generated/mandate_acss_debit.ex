defmodule Dhc.Stripe.MandateAcssDebit do
  @moduledoc """
  Provides struct and type for a MandateAcssDebit
  """

  @type t :: %__MODULE__{
          default_for: [String.t()] | nil,
          interval_description: String.t() | nil,
          payment_schedule: String.t(),
          transaction_type: String.t()
        }

  defstruct [:default_for, :interval_description, :payment_schedule, :transaction_type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      default_for: [enum: ["invoice", "subscription"]],
      interval_description: :string,
      payment_schedule: {:enum, ["combined", "interval", "sporadic"]},
      transaction_type: {:enum, ["business", "personal"]}
    ]
  end
end
