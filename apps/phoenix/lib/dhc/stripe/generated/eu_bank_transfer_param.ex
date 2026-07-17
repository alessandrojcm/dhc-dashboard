defmodule Dhc.Stripe.EuBankTransferParam do
  @moduledoc """
  Provides struct and types for a EuBankTransferParam
  """

  @type t :: %__MODULE__{country: String.t()}

  defstruct [:country]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [country: :string]
  end
end
