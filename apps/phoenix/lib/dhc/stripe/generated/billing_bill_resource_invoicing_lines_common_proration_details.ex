defmodule Dhc.Stripe.BillingBillResourceInvoicingLinesCommonProrationDetails do
  @moduledoc """
  Provides struct and type for a BillingBillResourceInvoicingLinesCommonProrationDetails
  """

  @type t :: %__MODULE__{
          credited_items:
            Dhc.Stripe.BillingBillResourceInvoicingLinesCommonCreditedItems.t() | nil
        }

  defstruct [:credited_items]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [credited_items: {Dhc.Stripe.BillingBillResourceInvoicingLinesCommonCreditedItems, :t}]
  end
end
