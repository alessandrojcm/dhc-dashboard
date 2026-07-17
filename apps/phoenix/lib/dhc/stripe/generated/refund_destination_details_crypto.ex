defmodule Dhc.Stripe.RefundDestinationDetailsCrypto do
  @moduledoc """
  Provides struct and type for a RefundDestinationDetailsCrypto
  """

  @type t :: %__MODULE__{reference: String.t() | nil}

  defstruct [:reference]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [reference: :string]
  end
end
