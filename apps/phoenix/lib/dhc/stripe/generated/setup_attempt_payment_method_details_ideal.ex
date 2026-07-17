defmodule Dhc.Stripe.SetupAttemptPaymentMethodDetailsIdeal do
  @moduledoc """
  Provides struct and type for a SetupAttemptPaymentMethodDetailsIdeal
  """

  @type t :: %__MODULE__{
          bank: String.t() | nil,
          bic: String.t() | nil,
          generated_sepa_debit: Dhc.Stripe.PaymentMethod.t() | String.t() | nil,
          generated_sepa_debit_mandate: Dhc.Stripe.Mandate.t() | String.t() | nil,
          iban_last4: String.t() | nil,
          verified_name: String.t() | nil
        }

  defstruct [
    :bank,
    :bic,
    :generated_sepa_debit,
    :generated_sepa_debit_mandate,
    :iban_last4,
    :verified_name
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      bank:
        {:enum,
         [
           "abn_amro",
           "adyen",
           "asn_bank",
           "bunq",
           "buut",
           "finom",
           "handelsbanken",
           "ing",
           "knab",
           "mollie",
           "moneyou",
           "n26",
           "nn",
           "rabobank",
           "regiobank",
           "revolut",
           "sns_bank",
           "triodos_bank",
           "van_lanschot",
           "yoursafe"
         ]},
      bic:
        {:enum,
         [
           "ABNANL2A",
           "ADYBNL2A",
           "ASNBNL21",
           "BITSNL2A",
           "BUNQNL2A",
           "BUUTNL2A",
           "FNOMNL22",
           "FVLBNL22",
           "HANDNL2A",
           "INGBNL2A",
           "KNABNL2H",
           "MLLENL2A",
           "MOYONL21",
           "NNBANL2G",
           "NTSBDEB1",
           "RABONL2U",
           "RBRBNL21",
           "REVOIE23",
           "REVOLT21",
           "SNSBNL2A",
           "TRIONL2U"
         ]},
      generated_sepa_debit: {:union, [:string, {Dhc.Stripe.PaymentMethod, :t}]},
      generated_sepa_debit_mandate: {:union, [:string, {Dhc.Stripe.Mandate, :t}]},
      iban_last4: :string,
      verified_name: :string
    ]
  end
end
