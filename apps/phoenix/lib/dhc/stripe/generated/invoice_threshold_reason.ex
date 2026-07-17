defmodule Dhc.Stripe.InvoiceThresholdReason do
  @moduledoc """
  Provides struct and type for a InvoiceThresholdReason
  """

  @type t :: %__MODULE__{
          amount_gte: integer | nil,
          item_reasons: [Dhc.Stripe.InvoiceItemThresholdReason.t()]
        }

  defstruct [:amount_gte, :item_reasons]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [amount_gte: :integer, item_reasons: [{Dhc.Stripe.InvoiceItemThresholdReason, :t}]]
  end
end
