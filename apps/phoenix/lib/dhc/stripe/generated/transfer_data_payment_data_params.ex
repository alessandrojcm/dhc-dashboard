defmodule Dhc.Stripe.TransferDataPaymentDataParams do
  @moduledoc """
  Provides struct and type for a TransferDataPaymentDataParams
  """

  @type t :: %__MODULE__{description: String.t() | nil, metadata: map | String.t() | nil}

  defstruct [:description, :metadata]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [description: :string, metadata: {:union, [:map, const: ""]}]
  end
end
