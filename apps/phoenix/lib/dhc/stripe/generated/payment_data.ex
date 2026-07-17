defmodule Dhc.Stripe.PaymentData do
  @moduledoc """
  Provides struct and type for a PaymentData
  """

  @type t :: %__MODULE__{description: String.t() | nil, metadata: map | nil}

  defstruct [:description, :metadata]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [description: :string, metadata: :map]
  end
end
