defmodule Dhc.Stripe.PaymentMethodDetailsFpx do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsFpx
  """

  @type t :: %__MODULE__{bank: String.t(), transaction_id: String.t() | nil}

  defstruct [:bank, :transaction_id]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      bank:
        {:enum,
         [
           "affin_bank",
           "agrobank",
           "alliance_bank",
           "ambank",
           "bank_islam",
           "bank_muamalat",
           "bank_of_china",
           "bank_rakyat",
           "bnp_paribas",
           "bsn",
           "cimb",
           "citibank",
           "deutsche_bank",
           "hong_leong_bank",
           "hsbc",
           "kfh",
           "maybank2e",
           "maybank2u",
           "mbsb_bank",
           "ocbc",
           "pb_enterprise",
           "public_bank",
           "rhb",
           "standard_chartered",
           "uob"
         ]},
      transaction_id: :string
    ]
  end
end
