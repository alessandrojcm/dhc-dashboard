defmodule Dhc.Stripe.PaymentMethodDetailsCrypto do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsCrypto
  """

  @type t :: %__MODULE__{
          buyer_address: String.t() | nil,
          network: String.t() | nil,
          token_currency: String.t() | nil,
          transaction_hash: String.t() | nil
        }

  defstruct [:buyer_address, :network, :token_currency, :transaction_hash]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      buyer_address: :string,
      network: {:enum, ["base", "ethereum", "polygon", "solana", "sui", "tempo"]},
      token_currency: {:enum, ["phantom_cash", "usdc", "usdg", "usdp", "usdsui", "usdt"]},
      transaction_hash: :string
    ]
  end
end
