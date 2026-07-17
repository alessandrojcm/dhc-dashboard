defmodule Dhc.Stripe.TaxIdVerification do
  @moduledoc """
  Provides struct and type for a TaxIdVerification
  """

  @type t :: %__MODULE__{
          status: String.t(),
          verified_address: String.t() | nil,
          verified_name: String.t() | nil
        }

  defstruct [:status, :verified_address, :verified_name]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      status: {:enum, ["pending", "unavailable", "unverified", "verified"]},
      verified_address: :string,
      verified_name: :string
    ]
  end
end
