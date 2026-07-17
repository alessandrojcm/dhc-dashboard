defmodule Dhc.Stripe.IssuingTransactionFleetData do
  @moduledoc """
  Provides struct and type for a IssuingTransactionFleetData
  """

  @type t :: %__MODULE__{
          cardholder_prompt_data:
            Dhc.Stripe.IssuingTransactionFleetCardholderPromptData.t() | nil,
          purchase_type: String.t() | nil,
          reported_breakdown: Dhc.Stripe.IssuingTransactionFleetReportedBreakdown.t() | nil,
          service_type: String.t() | nil
        }

  defstruct [:cardholder_prompt_data, :purchase_type, :reported_breakdown, :service_type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      cardholder_prompt_data: {Dhc.Stripe.IssuingTransactionFleetCardholderPromptData, :t},
      purchase_type: :string,
      reported_breakdown: {Dhc.Stripe.IssuingTransactionFleetReportedBreakdown, :t},
      service_type: :string
    ]
  end
end
