defmodule Dhc.Stripe.PaymentMethodDetailsPaymentRecordBancontact do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsPaymentRecordBancontact
  """

  @type t :: %__MODULE__{
          bank_code: String.t() | nil,
          bank_name: String.t() | nil,
          bic: String.t() | nil,
          generated_sepa_debit: Dhc.Stripe.PaymentMethod.t() | String.t() | nil,
          generated_sepa_debit_mandate: Dhc.Stripe.Mandate.t() | String.t() | nil,
          iban_last4: String.t() | nil,
          preferred_language: String.t() | nil,
          verified_name: String.t() | nil
        }

  defstruct [
    :bank_code,
    :bank_name,
    :bic,
    :generated_sepa_debit,
    :generated_sepa_debit_mandate,
    :iban_last4,
    :preferred_language,
    :verified_name
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      bank_code: :string,
      bank_name: :string,
      bic: :string,
      generated_sepa_debit: {:union, [:string, {Dhc.Stripe.PaymentMethod, :t}]},
      generated_sepa_debit_mandate: {:union, [:string, {Dhc.Stripe.Mandate, :t}]},
      iban_last4: :string,
      preferred_language: {:enum, ["de", "en", "fr", "nl"]},
      verified_name: :string
    ]
  end
end
