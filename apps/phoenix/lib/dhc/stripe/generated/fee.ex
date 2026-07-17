defmodule Dhc.Stripe.Fee do
  @moduledoc """
  Provides struct and type for a Fee
  """

  @type t :: %__MODULE__{
          amount: integer,
          application: String.t() | nil,
          currency: String.t(),
          description: String.t() | nil,
          type: String.t()
        }

  defstruct [:amount, :application, :currency, :description, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      application: :string,
      currency: {:string, "currency"},
      description: :string,
      type: :string
    ]
  end
end
