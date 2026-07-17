defmodule Dhc.Stripe.PaymentMethodOptionsCardPresentRouting do
  @moduledoc """
  Provides struct and type for a PaymentMethodOptionsCardPresentRouting
  """

  @type t :: %__MODULE__{requested_priority: String.t() | nil}

  defstruct [:requested_priority]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [requested_priority: {:enum, ["domestic", "international"]}]
  end
end
