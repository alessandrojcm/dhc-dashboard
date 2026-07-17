defmodule Dhc.Stripe.MandateUpi do
  @moduledoc """
  Provides struct and type for a MandateUpi
  """

  @type t :: %__MODULE__{
          amount: integer | nil,
          amount_type: String.t() | nil,
          description: String.t() | nil,
          end_date: integer | nil
        }

  defstruct [:amount, :amount_type, :description, :end_date]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      amount_type: {:enum, ["fixed", "maximum"]},
      description: :string,
      end_date: {:integer, "unix-time"}
    ]
  end
end
