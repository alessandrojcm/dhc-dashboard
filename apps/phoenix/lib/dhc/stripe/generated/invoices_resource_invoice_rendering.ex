defmodule Dhc.Stripe.InvoicesResourceInvoiceRendering do
  @moduledoc """
  Provides struct and type for a InvoicesResourceInvoiceRendering
  """

  @type t :: %__MODULE__{
          amount_tax_display: String.t() | nil,
          pdf: Dhc.Stripe.InvoiceRenderingPdf.t() | nil,
          template: String.t() | nil,
          template_version: integer | nil
        }

  defstruct [:amount_tax_display, :pdf, :template, :template_version]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount_tax_display: :string,
      pdf: {Dhc.Stripe.InvoiceRenderingPdf, :t},
      template: :string,
      template_version: :integer
    ]
  end
end
