defmodule Dhc.Stripe.IssuingNetworkTokenNetworkData do
  @moduledoc """
  Provides struct and type for a IssuingNetworkTokenNetworkData
  """

  @type t :: %__MODULE__{
          device: Dhc.Stripe.IssuingNetworkTokenDevice.t() | nil,
          mastercard: Dhc.Stripe.IssuingNetworkTokenMastercard.t() | nil,
          type: String.t(),
          visa: Dhc.Stripe.IssuingNetworkTokenVisa.t() | nil,
          wallet_provider: Dhc.Stripe.IssuingNetworkTokenWalletProvider.t() | nil
        }

  defstruct [:device, :mastercard, :type, :visa, :wallet_provider]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      device: {Dhc.Stripe.IssuingNetworkTokenDevice, :t},
      mastercard: {Dhc.Stripe.IssuingNetworkTokenMastercard, :t},
      type: {:enum, ["mastercard", "visa"]},
      visa: {Dhc.Stripe.IssuingNetworkTokenVisa, :t},
      wallet_provider: {Dhc.Stripe.IssuingNetworkTokenWalletProvider, :t}
    ]
  end
end
