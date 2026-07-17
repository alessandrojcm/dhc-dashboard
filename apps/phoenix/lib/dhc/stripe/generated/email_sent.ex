defmodule Dhc.Stripe.EmailSent do
  @moduledoc """
  Provides struct and type for a EmailSent
  """

  @type t :: %__MODULE__{email_sent_at: integer, email_sent_to: String.t()}

  defstruct [:email_sent_at, :email_sent_to]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [email_sent_at: {:integer, "unix-time"}, email_sent_to: :string]
  end
end
