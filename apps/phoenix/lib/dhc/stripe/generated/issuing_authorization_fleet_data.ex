defmodule Dhc.Stripe.IssuingAuthorizationFleetData do
  @moduledoc """
  Provides struct and type for a IssuingAuthorizationFleetData
  """

  @type t :: %__MODULE__{
          cardholder_prompt_data:
            Dhc.Stripe.IssuingAuthorizationFleetCardholderPromptData.t() | nil,
          purchase_type: String.t() | nil,
          reported_breakdown: Dhc.Stripe.IssuingAuthorizationFleetReportedBreakdown.t() | nil,
          service_type: String.t() | nil
        }

  defstruct [:cardholder_prompt_data, :purchase_type, :reported_breakdown, :service_type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      cardholder_prompt_data: {Dhc.Stripe.IssuingAuthorizationFleetCardholderPromptData, :t},
      purchase_type:
        {:enum, ["fuel_and_non_fuel_purchase", "fuel_purchase", "non_fuel_purchase"]},
      reported_breakdown: {Dhc.Stripe.IssuingAuthorizationFleetReportedBreakdown, :t},
      service_type: {:enum, ["full_service", "non_fuel_transaction", "self_service"]}
    ]
  end
end
