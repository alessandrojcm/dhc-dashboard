defmodule Dhc.Stripe.MandateUsBankAccount do
  @moduledoc """
  Provides struct and type for a MandateUsBankAccount
  """

  @type t :: %__MODULE__{collection_method: String.t() | nil}

  defstruct [:collection_method]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [collection_method: {:const, "paper"}]
  end
end
