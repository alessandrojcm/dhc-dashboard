defmodule Dhc.Stripe.ChargeOutcome do
  @moduledoc """
  Provides struct and type for a ChargeOutcome
  """

  @type t :: %__MODULE__{
          advice_code: String.t() | nil,
          network_advice_code: String.t() | nil,
          network_decline_code: String.t() | nil,
          network_status: String.t() | nil,
          reason: String.t() | nil,
          risk_level: String.t() | nil,
          risk_score: integer | nil,
          rule: Dhc.Stripe.Rule.t() | String.t() | nil,
          seller_message: String.t() | nil,
          type: String.t()
        }

  defstruct [
    :advice_code,
    :network_advice_code,
    :network_decline_code,
    :network_status,
    :reason,
    :risk_level,
    :risk_score,
    :rule,
    :seller_message,
    :type
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      advice_code: {:enum, ["confirm_card_data", "do_not_try_again", "try_again_later"]},
      network_advice_code: :string,
      network_decline_code: :string,
      network_status: :string,
      reason: :string,
      risk_level: :string,
      risk_score: :integer,
      rule: {:union, [:string, {Dhc.Stripe.Rule, :t}]},
      seller_message: :string,
      type: :string
    ]
  end
end
