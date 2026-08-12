defmodule Dhc.Stripe.ThreeDSecureDetails do
  @moduledoc """
  Provides struct and type for a ThreeDSecureDetails
  """

  @type t :: %__MODULE__{
          authentication_flow: String.t() | nil,
          electronic_commerce_indicator: String.t() | nil,
          result: String.t() | nil,
          result_reason: String.t() | nil,
          transaction_id: String.t() | nil,
          version: String.t() | nil
        }

  defstruct [
    :authentication_flow,
    :electronic_commerce_indicator,
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
