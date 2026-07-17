defmodule Dhc.Stripe.PaymentLinksResourceCompletedSessions do
  @moduledoc """
  Provides struct and type for a PaymentLinksResourceCompletedSessions
  """

  @type t :: %__MODULE__{count: integer, limit: integer}

  defstruct [:count, :limit]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [count: :integer, limit: :integer]
  end
end
