defmodule Dhc.Stripe.PaymentMethodKrCard do
  @moduledoc """
  Provides struct and type for a PaymentMethodKrCard
  """

  @type t :: %__MODULE__{brand: String.t() | nil, last4: String.t() | nil}

  defstruct [:brand, :last4]

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
      last4: :string
    ]
  end
end
