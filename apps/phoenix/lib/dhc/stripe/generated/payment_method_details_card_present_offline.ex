defmodule Dhc.Stripe.PaymentMethodDetailsCardPresentOffline do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsCardPresentOffline
  """

  @type t :: %__MODULE__{stored_at: integer | nil, type: String.t() | nil}

  defstruct [:stored_at, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [stored_at: {:integer, "unix-time"}, type: {:const, "deferred"}]
  end
end
