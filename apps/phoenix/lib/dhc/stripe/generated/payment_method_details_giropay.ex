defmodule Dhc.Stripe.PaymentMethodDetailsGiropay do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsGiropay
  """

  @type t :: %__MODULE__{
          bank_code: String.t() | nil,
          bank_name: String.t() | nil,
          bic: String.t() | nil,
          verified_name: String.t() | nil
        }

  defstruct [:bank_code, :bank_name, :bic, :verified_name]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [bank_code: :string, bank_name: :string, bic: :string, verified_name: :string]
  end
end
