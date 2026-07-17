defmodule Dhc.Stripe.PaymentMethodDetailsPaypal do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsPaypal
  """

  @type t :: %__MODULE__{
          country: String.t() | nil,
          payer_email: String.t() | nil,
          payer_id: String.t() | nil,
          payer_name: String.t() | nil,
          seller_protection: Dhc.Stripe.PaypalSellerProtection.t() | nil,
          transaction_id: String.t() | nil
        }

  defstruct [:country, :payer_email, :payer_id, :payer_name, :seller_protection, :transaction_id]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      country: :string,
      payer_email: :string,
      payer_id: :string,
      payer_name: :string,
      seller_protection: {Dhc.Stripe.PaypalSellerProtection, :t},
      transaction_id: :string
    ]
  end
end
