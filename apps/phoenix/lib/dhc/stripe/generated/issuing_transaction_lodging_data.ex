defmodule Dhc.Stripe.IssuingTransactionLodgingData do
  @moduledoc """
  Provides struct and type for a IssuingTransactionLodgingData
  """

  @type t :: %__MODULE__{check_in_at: integer | nil, nights: integer | nil}

  defstruct [:check_in_at, :nights]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [check_in_at: :integer, nights: :integer]
  end
end
