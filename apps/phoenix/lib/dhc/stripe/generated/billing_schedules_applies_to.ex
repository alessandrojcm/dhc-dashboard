defmodule Dhc.Stripe.BillingSchedulesAppliesTo do
  @moduledoc """
  Provides struct and type for a BillingSchedulesAppliesTo
  """

  @type t :: %__MODULE__{price: String.t() | nil, type: String.t()}

  defstruct [:price, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [price: :string, type: {:const, "price"}]
  end
end
