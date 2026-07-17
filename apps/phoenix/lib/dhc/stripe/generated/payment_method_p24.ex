defmodule Dhc.Stripe.PaymentMethodP24 do
  @moduledoc """
  Provides struct and type for a PaymentMethodP24
  """

  @type t :: %__MODULE__{bank: String.t() | nil}

  defstruct [:bank]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      bank:
        {:enum,
         [
           "alior_bank",
           "bank_millennium",
           "bank_nowy_bfg_sa",
           "bank_pekao_sa",
           "banki_spbdzielcze",
           "blik",
           "bnp_paribas",
           "boz",
           "citi_handlowy",
           "credit_agricole",
           "envelobank",
           "etransfer_pocztowy24",
           "getin_bank",
           "ideabank",
           "ing",
           "inteligo",
           "mbank_mtransfer",
           "nest_przelew",
           "noble_pay",
           "pbac_z_ipko",
           "plus_bank",
           "santander_przelew24",
           "tmobile_usbugi_bankowe",
           "toyota_bank",
           "velobank",
           "volkswagen_bank"
         ]}
    ]
  end
end
