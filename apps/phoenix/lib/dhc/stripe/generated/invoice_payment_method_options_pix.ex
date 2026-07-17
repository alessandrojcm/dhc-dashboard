defmodule Dhc.Stripe.InvoicePaymentMethodOptionsPix do
  @moduledoc """
  Provides struct and type for a InvoicePaymentMethodOptionsPix
  """

  @type t :: %__MODULE__{
          amount_includes_iof: String.t() | nil,
          expires_after_seconds: integer | nil
        }

  defstruct [:amount_includes_iof, :expires_after_seconds]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [amount_includes_iof: {:enum, ["always", "never"]}, expires_after_seconds: :integer]
  end
end
