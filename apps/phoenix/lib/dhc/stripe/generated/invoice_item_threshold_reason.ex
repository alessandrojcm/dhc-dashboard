defmodule Dhc.Stripe.InvoiceItemThresholdReason do
  @moduledoc """
  Provides struct and type for a InvoiceItemThresholdReason
  """

  @type t :: %__MODULE__{line_item_ids: [String.t()], usage_gte: integer}

  defstruct [:line_item_ids, :usage_gte]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [line_item_ids: [:string], usage_gte: :integer]
  end
end
