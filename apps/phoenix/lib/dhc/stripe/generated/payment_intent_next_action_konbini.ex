defmodule Dhc.Stripe.PaymentIntentNextActionKonbini do
  @moduledoc """
  Provides struct and type for a PaymentIntentNextActionKonbini
  """

  @type t :: %__MODULE__{
          expires_at: integer,
          hosted_voucher_url: String.t() | nil,
          stores: Dhc.Stripe.PaymentIntentNextActionKonbiniStores.t()
        }

  defstruct [:expires_at, :hosted_voucher_url, :stores]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      expires_at: {:integer, "unix-time"},
      hosted_voucher_url: :string,
      stores: {Dhc.Stripe.PaymentIntentNextActionKonbiniStores, :t}
    ]
  end
end
