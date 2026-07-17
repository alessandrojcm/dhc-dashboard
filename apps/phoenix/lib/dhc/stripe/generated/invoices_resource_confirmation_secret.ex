defmodule Dhc.Stripe.InvoicesResourceConfirmationSecret do
  @moduledoc """
  Provides struct and type for a InvoicesResourceConfirmationSecret
  """

  @type t :: %__MODULE__{client_secret: String.t(), type: String.t()}

  defstruct [:client_secret, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [client_secret: :string, type: :string]
  end
end
