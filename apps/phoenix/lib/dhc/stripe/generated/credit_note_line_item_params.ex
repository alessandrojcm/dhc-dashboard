defmodule Dhc.Stripe.CreditNoteLineItemParams do
  @moduledoc """
  Provides struct and type for a CreditNoteLineItemParams
  """

  @type t :: %__MODULE__{
          amount: integer | nil,
          description: String.t() | nil,
          invoice_line_item: String.t() | nil,
          metadata: map | nil,
          quantity: integer | nil,
          tax_amounts: String.t() | [map] | nil,
          tax_rates: String.t() | [String.t()] | nil,
          type: String.t(),
          unit_amount: integer | nil,
          unit_amount_decimal: String.t() | nil
        }

  defstruct [
    :amount,
    :description,
    :invoice_line_item,
    :metadata,
    :quantity,
    :tax_amounts,
    :tax_rates,
    :type,
    :unit_amount,
    :unit_amount_decimal
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      description: :string,
      invoice_line_item: :string,
      metadata: :map,
      quantity: :integer,
      tax_amounts: {:union, [{:const, ""}, [:map]]},
      tax_rates: {:union, [{:const, ""}, [:string]]},
      type: {:enum, ["custom_line_item", "invoice_line_item"]},
      unit_amount: :integer,
      unit_amount_decimal: {:string, "decimal"}
    ]
  end
end
