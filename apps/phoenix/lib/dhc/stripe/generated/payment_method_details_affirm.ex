defmodule Dhc.Stripe.PaymentMethodDetailsAffirm do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsAffirm
  """

  @type t :: %__MODULE__{
          location: String.t() | nil,
          reader: String.t() | nil,
          transaction_id: String.t() | nil
        }

  defstruct [:location, :reader, :transaction_id]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [location: :string, reader: :string, transaction_id: :string]
  end
end
