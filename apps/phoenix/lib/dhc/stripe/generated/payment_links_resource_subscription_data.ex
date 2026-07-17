defmodule Dhc.Stripe.PaymentLinksResourceSubscriptionData do
  @moduledoc """
  Provides struct and type for a PaymentLinksResourceSubscriptionData
  """

  @type t :: %__MODULE__{
          description: String.t() | nil,
          invoice_settings: Dhc.Stripe.PaymentLinksResourceSubscriptionDataInvoiceSettings.t(),
          metadata: map,
          trial_period_days: integer | nil,
          trial_settings: Dhc.Stripe.SubscriptionsTrialsResourceTrialSettings.t() | nil
        }

  defstruct [:description, :invoice_settings, :metadata, :trial_period_days, :trial_settings]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      description: :string,
      invoice_settings: {Dhc.Stripe.PaymentLinksResourceSubscriptionDataInvoiceSettings, :t},
      metadata: :map,
      trial_period_days: :integer,
      trial_settings: {Dhc.Stripe.SubscriptionsTrialsResourceTrialSettings, :t}
    ]
  end
end
