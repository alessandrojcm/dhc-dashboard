defmodule Dhc.Stripe.InvoiceCreationParams do
  @moduledoc """
  Provides struct and type for a InvoiceCreationParams
  """

  @type t :: %__MODULE__{enabled: boolean, invoice_data: Dhc.Stripe.InvoiceDataParams.t() | nil}

  defstruct [:enabled, :invoice_data]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [enabled: :boolean, invoice_data: {Dhc.Stripe.InvoiceDataParams, :t}]
  end
end
