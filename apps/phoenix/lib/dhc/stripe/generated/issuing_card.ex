defmodule Dhc.Stripe.IssuingCard do
  @moduledoc """
  Provides struct and type for a IssuingCard
  """

  @type t :: %__MODULE__{
          brand: String.t(),
          cancellation_reason: String.t() | nil,
          cardholder: Dhc.Stripe.IssuingCardholder.t(),
          created: integer,
          currency: String.t(),
          cvc: String.t() | nil,
          exp_month: integer,
          exp_year: integer,
          financial_account: String.t() | nil,
          id: String.t(),
          last4: String.t(),
          latest_fraud_warning: Dhc.Stripe.IssuingCardFraudWarning.t() | nil,
          lifecycle_controls: Dhc.Stripe.IssuingCardLifecycleControls.t() | nil,
          livemode: boolean,
          metadata: map,
          number: String.t() | nil,
          object: String.t(),
          personalization_design: Dhc.Stripe.IssuingPersonalizationDesign.t() | String.t() | nil,
          replaced_by: Dhc.Stripe.IssuingCard.t() | String.t() | nil,
          replacement_for: Dhc.Stripe.IssuingCard.t() | String.t() | nil,
          replacement_reason: String.t() | nil,
          second_line: String.t() | nil,
          shipping: Dhc.Stripe.IssuingCardShipping.t() | nil,
          spending_controls: Dhc.Stripe.IssuingCardAuthorizationControls.t(),
          status: String.t(),
          type: String.t(),
          wallets: Dhc.Stripe.IssuingCardWallets.t() | nil
        }

  defstruct [
    :brand,
    :cancellation_reason,
    :cardholder,
    :created,
    :currency,
    :cvc,
    :exp_month,
    :exp_year,
    :financial_account,
    :id,
    :last4,
    :latest_fraud_warning,
    :lifecycle_controls,
    :livemode,
    :metadata,
    :number,
    :object,
    :personalization_design,
    :replaced_by,
    :replacement_for,
    :replacement_reason,
    :second_line,
    :shipping,
    :spending_controls,
    :status,
    :type,
    :wallets
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      brand: :string,
      cancellation_reason: {:enum, ["design_rejected", "fulfillment_error", "lost", "stolen"]},
      cardholder: {Dhc.Stripe.IssuingCardholder, :t},
      created: {:integer, "unix-time"},
      currency: {:string, "currency"},
      cvc: :string,
      exp_month: :integer,
      exp_year: :integer,
      financial_account: :string,
      id: :string,
      last4: :string,
      latest_fraud_warning: {Dhc.Stripe.IssuingCardFraudWarning, :t},
      lifecycle_controls: {Dhc.Stripe.IssuingCardLifecycleControls, :t},
      livemode: :boolean,
      metadata: :map,
      number: :string,
      object: {:const, "issuing.card"},
      personalization_design: {:union, [:string, {Dhc.Stripe.IssuingPersonalizationDesign, :t}]},
      replaced_by: {:union, [:string, {Dhc.Stripe.IssuingCard, :t}]},
      replacement_for: {:union, [:string, {Dhc.Stripe.IssuingCard, :t}]},
      replacement_reason: {:enum, ["damaged", "expired", "fulfillment_error", "lost", "stolen"]},
      second_line: :string,
      shipping: {Dhc.Stripe.IssuingCardShipping, :t},
      spending_controls: {Dhc.Stripe.IssuingCardAuthorizationControls, :t},
      status: {:enum, ["active", "canceled", "inactive"]},
      type: {:enum, ["physical", "virtual"]},
      wallets: {Dhc.Stripe.IssuingCardWallets, :t}
    ]
  end
end
