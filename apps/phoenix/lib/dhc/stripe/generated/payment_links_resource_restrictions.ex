defmodule Dhc.Stripe.PaymentLinksResourceRestrictions do
  @moduledoc """
  Provides struct and type for a PaymentLinksResourceRestrictions
  """

  @type t :: %__MODULE__{completed_sessions: Dhc.Stripe.PaymentLinksResourceCompletedSessions.t()}

  defstruct [:completed_sessions]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [completed_sessions: {Dhc.Stripe.PaymentLinksResourceCompletedSessions, :t}]
  end
end
