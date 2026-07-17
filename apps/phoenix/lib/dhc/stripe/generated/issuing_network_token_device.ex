defmodule Dhc.Stripe.IssuingNetworkTokenDevice do
  @moduledoc """
  Provides struct and type for a IssuingNetworkTokenDevice
  """

  @type t :: %__MODULE__{
          device_fingerprint: String.t() | nil,
          ip_address: String.t() | nil,
          location: String.t() | nil,
          name: String.t() | nil,
          phone_number: String.t() | nil,
          type: String.t() | nil
        }

  defstruct [:device_fingerprint, :ip_address, :location, :name, :phone_number, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      device_fingerprint: :string,
      ip_address: :string,
      location: :string,
      name: :string,
      phone_number: :string,
      type: {:enum, ["other", "phone", "watch"]}
    ]
  end
end
