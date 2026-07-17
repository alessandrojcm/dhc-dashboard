defmodule Dhc.Stripe.MandateSepaDebit do
  @moduledoc """
  Provides struct and type for a MandateSepaDebit
  """

  @type t :: %__MODULE__{reference: String.t(), url: String.t()}

  defstruct [:reference, :url]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [reference: :string, url: :string]
  end
end
