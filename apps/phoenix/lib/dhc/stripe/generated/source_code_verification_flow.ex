defmodule Dhc.Stripe.SourceCodeVerificationFlow do
  @moduledoc """
  Provides struct and type for a SourceCodeVerificationFlow
  """

  @type t :: %__MODULE__{attempts_remaining: integer, status: String.t()}

  defstruct [:attempts_remaining, :status]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [attempts_remaining: :integer, status: :string]
  end
end
