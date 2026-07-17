defmodule Dhc.Stripe.InvoiceSettingsParams do
  @moduledoc """
  Provides struct and type for a InvoiceSettingsParams
  """

  @type t :: %__MODULE__{issuer: Dhc.Stripe.Param.t() | nil}

  defstruct [:issuer]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [issuer: {Dhc.Stripe.Param, :t}]
  end
end
