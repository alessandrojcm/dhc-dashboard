defmodule Dhc.Stripe.ThreeDSecureDetailsCharge do
  @moduledoc """
  Provides struct and type for a ThreeDSecureDetailsCharge
  """

  @type t :: %__MODULE__{
          authentication_flow: String.t() | nil,
          electronic_commerce_indicator: String.t() | nil,
          exemption_indicator: String.t() | nil,
          exemption_indicator_applied: boolean | nil,
          result: String.t() | nil,
          result_reason: String.t() | nil,
          transaction_id: String.t() | nil,
          version: String.t() | nil
        }

  defstruct [
    :authentication_flow,
    :electronic_commerce_indicator,
    :exemption_indicator,
    :exemption_indicator_applied,
    :result,
    :result_reason,
    :transaction_id,
    :version
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      authentication_flow: {:enum, ["challenge", "frictionless"]},
      electronic_commerce_indicator: {:enum, ["01", "02", "05", "06", "07"]},
      exemption_indicator: {:enum, ["low_risk", "none"]},
      exemption_indicator_applied: :boolean,
      result:
        {:enum,
         [
           "attempt_acknowledged",
           "authenticated",
           "data_share_only",
           "exempted",
           "failed",
           "not_supported",
           "processing_error"
         ]},
      result_reason:
        {:enum,
         [
           "abandoned",
           "bypassed",
           "canceled",
           "card_not_enrolled",
           "network_not_supported",
           "protocol_error",
           "rejected"
         ]},
      transaction_id: :string,
      version: {:enum, ["1.0.2", "2.1.0", "2.2.0", "2.3.0", "2.3.1"]}
    ]
  end
end
