defmodule Dhc.Stripe.CustomerUpdateParams do
  @moduledoc """
  Provides struct and type for a CustomerUpdateParams
  """

  @type t :: %__MODULE__{
          address: String.t() | nil,
          name: String.t() | nil,
          shipping: String.t() | nil
        }

  defstruct [:address, :name, :shipping]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      address: {:enum, ["auto", "never"]},
      name: {:enum, ["auto", "never"]},
      shipping: {:enum, ["auto", "never"]}
    ]
  end
end
