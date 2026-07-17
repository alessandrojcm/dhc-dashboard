defmodule Dhc.Stripe.InvoicesResourceStatusTransitions do
  @moduledoc """
  Provides struct and type for a InvoicesResourceStatusTransitions
  """

  @type t :: %__MODULE__{
          finalized_at: integer | nil,
          marked_uncollectible_at: integer | nil,
          paid_at: integer | nil,
          voided_at: integer | nil
        }

  defstruct [:finalized_at, :marked_uncollectible_at, :paid_at, :voided_at]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      finalized_at: {:integer, "unix-time"},
      marked_uncollectible_at: {:integer, "unix-time"},
      paid_at: {:integer, "unix-time"},
      voided_at: {:integer, "unix-time"}
    ]
  end
end
