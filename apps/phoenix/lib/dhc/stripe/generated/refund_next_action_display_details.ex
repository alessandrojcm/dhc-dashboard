defmodule Dhc.Stripe.RefundNextActionDisplayDetails do
  @moduledoc """
  Provides struct and type for a RefundNextActionDisplayDetails
  """

  @type t :: %__MODULE__{email_sent: Dhc.Stripe.EmailSent.t(), expires_at: integer}

  defstruct [:email_sent, :expires_at]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [email_sent: {Dhc.Stripe.EmailSent, :t}, expires_at: {:integer, "unix-time"}]
  end
end
