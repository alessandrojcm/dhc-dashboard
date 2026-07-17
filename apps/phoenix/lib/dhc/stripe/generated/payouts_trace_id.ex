defmodule Dhc.Stripe.PayoutsTraceId do
  @moduledoc """
  Provides struct and type for a PayoutsTraceId
  """

  @type t :: %__MODULE__{status: String.t(), value: String.t() | nil}

  defstruct [:status, :value]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [status: :string, value: :string]
  end
end
