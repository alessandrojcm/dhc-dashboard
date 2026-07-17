defmodule Dhc.Stripe.RefundDestinationDetailsPaypal do
  @moduledoc """
  Provides struct and type for a RefundDestinationDetailsPaypal
  """

  @type t :: %__MODULE__{network_decline_code: String.t() | nil}

  defstruct [:network_decline_code]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [network_decline_code: :string]
  end
end
