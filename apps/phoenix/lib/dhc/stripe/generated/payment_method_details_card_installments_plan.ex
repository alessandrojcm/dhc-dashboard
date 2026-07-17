defmodule Dhc.Stripe.PaymentMethodDetailsCardInstallmentsPlan do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsCardInstallmentsPlan
  """

  @type t :: %__MODULE__{count: integer | nil, interval: String.t() | nil, type: String.t()}

  defstruct [:count, :interval, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      count: :integer,
      interval: {:const, "month"},
      type: {:enum, ["bonus", "fixed_count", "revolving"]}
    ]
  end
end
