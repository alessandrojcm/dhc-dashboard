defmodule Dhc.Stripe.IssuingToken do
  @moduledoc """
  Provides struct and type for a IssuingToken
  """

  @type t :: %__MODULE__{
          card: Dhc.Stripe.IssuingCard.t() | String.t(),
          created: integer,
          device_fingerprint: String.t() | nil,
          id: String.t(),
          last4: String.t() | nil,
          livemode: boolean,
          network: String.t(),
          network_data: Dhc.Stripe.IssuingNetworkTokenNetworkData.t() | nil,
          network_updated_at: integer,
          object: String.t(),
          status: String.t(),
          wallet_provider: String.t() | nil
        }

  defstruct [
    :card,
    :created,
    :device_fingerprint,
    :id,
    :last4,
    :livemode,
    :network,
    :network_data,
    :network_updated_at,
    :object,
    :status,
    :wallet_provider
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      card: {:union, [:string, {Dhc.Stripe.IssuingCard, :t}]},
      created: {:integer, "unix-time"},
      device_fingerprint: :string,
      id: :string,
      last4: :string,
      livemode: :boolean,
      network: {:enum, ["mastercard", "visa"]},
      network_data: {Dhc.Stripe.IssuingNetworkTokenNetworkData, :t},
      network_updated_at: {:integer, "unix-time"},
      object: {:const, "issuing.token"},
      status: {:enum, ["active", "deleted", "requested", "suspended"]},
      wallet_provider: {:enum, ["apple_pay", "google_pay", "samsung_pay"]}
    ]
  end
end
