defmodule Dhc.Stripe.PaymentMethodUpi do
  @moduledoc """
  Provides struct and type for a PaymentMethodUpi
  """

  @type t :: %__MODULE__{vpa: String.t() | nil}

  defstruct [:vpa]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [vpa: :string]
  end
end
