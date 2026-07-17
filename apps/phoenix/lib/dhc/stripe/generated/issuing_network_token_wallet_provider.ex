defmodule Dhc.Stripe.IssuingNetworkTokenWalletProvider do
  @moduledoc """
  Provides struct and type for a IssuingNetworkTokenWalletProvider
  """

  @type t :: %__MODULE__{
          account_id: String.t() | nil,
          account_trust_score: integer | nil,
          card_number_source: String.t() | nil,
          cardholder_address: Dhc.Stripe.IssuingNetworkTokenAddress.t() | nil,
          cardholder_name: String.t() | nil,
          device_trust_score: integer | nil,
          hashed_account_email_address: String.t() | nil,
          reason_codes: [String.t()] | nil,
          suggested_decision: String.t() | nil,
          suggested_decision_version: String.t() | nil
        }

  defstruct [
    :account_id,
    :account_trust_score,
    :card_number_source,
    :cardholder_address,
    :cardholder_name,
    :device_trust_score,
    :hashed_account_email_address,
    :reason_codes,
    :suggested_decision,
    :suggested_decision_version
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      account_id: :string,
      account_trust_score: :integer,
      card_number_source: {:enum, ["app", "manual", "on_file", "other"]},
      cardholder_address: {Dhc.Stripe.IssuingNetworkTokenAddress, :t},
      cardholder_name: :string,
      device_trust_score: :integer,
      hashed_account_email_address: :string,
      reason_codes: [
        enum: [
          "account_card_too_new",
          "account_recently_changed",
          "account_too_new",
          "account_too_new_since_launch",
          "additional_device",
          "data_expired",
          "defer_id_v_decision",
          "device_recently_lost",
          "good_activity_history",
          "has_suspended_tokens",
          "high_risk",
          "inactive_account",
          "long_account_tenure",
          "low_account_score",
          "low_device_score",
          "low_phone_number_score",
          "network_service_error",
          "outside_home_territory",
          "provisioning_cardholder_mismatch",
          "provisioning_device_and_cardholder_mismatch",
          "provisioning_device_mismatch",
          "same_device_no_prior_authentication",
          "same_device_successful_prior_authentication",
          "software_update",
          "suspicious_activity",
          "too_many_different_cardholders",
          "too_many_recent_attempts",
          "too_many_recent_tokens"
        ]
      ],
      suggested_decision: {:enum, ["approve", "decline", "require_auth"]},
      suggested_decision_version: :string
    ]
  end
end
