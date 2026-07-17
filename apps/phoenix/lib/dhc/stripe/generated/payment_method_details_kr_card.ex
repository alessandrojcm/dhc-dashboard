defmodule Dhc.Stripe.PaymentMethodDetailsKrCard do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsKrCard
  """

  @type t :: %__MODULE__{
          brand: String.t() | nil,
          buyer_id: String.t() | nil,
          last4: String.t() | nil,
          transaction_id: String.t() | nil
        }

  defstruct [:brand, :buyer_id, :last4, :transaction_id]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      brand:
        {:enum,
         [
           "bc",
           "citi",
           "hana",
           "hyundai",
           "jeju",
           "jeonbuk",
           "kakaobank",
           "kbank",
           "kdbbank",
           "kookmin",
           "kwangju",
           "lotte",
           "mg",
           "nh",
           "post",
           "samsung",
           "savingsbank",
           "shinhan",
           "shinhyup",
           "suhyup",
           "tossbank",
           "woori"
         ]},
      buyer_id: :string,
      last4: :string,
      transaction_id: :string
    ]
  end
end
