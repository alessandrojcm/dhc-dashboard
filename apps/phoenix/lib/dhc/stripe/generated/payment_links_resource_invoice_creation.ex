defmodule Dhc.Stripe.PaymentLinksResourceInvoiceCreation do
  @moduledoc """
  Provides struct and type for a PaymentLinksResourceInvoiceCreation
  """

  @type t :: %__MODULE__{
          enabled: boolean,
          invoice_data: Dhc.Stripe.PaymentLinksResourceInvoiceSettings.t() | nil
        }

  defstruct [:enabled, :invoice_data]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [enabled: :boolean, invoice_data: {Dhc.Stripe.PaymentLinksResourceInvoiceSettings, :t}]
  end
end
