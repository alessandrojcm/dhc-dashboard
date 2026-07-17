defmodule Dhc.Stripe.BillingCreditGrantsResourceBalanceCreditsApplicationInvoiceVoided do
  @moduledoc """
  Provides struct and type for a BillingCreditGrantsResourceBalanceCreditsApplicationInvoiceVoided
  """

  @type t :: %__MODULE__{
          invoice: Dhc.Stripe.Invoice.t() | String.t(),
          invoice_line_item: String.t()
        }

  defstruct [:invoice, :invoice_line_item]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [invoice: {:union, [:string, {Dhc.Stripe.Invoice, :t}]}, invoice_line_item: :string]
  end
end
