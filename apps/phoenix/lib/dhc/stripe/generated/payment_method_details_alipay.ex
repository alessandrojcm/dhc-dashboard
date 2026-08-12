defmodule Dhc.Stripe.PaymentMethodDetailsAlipay do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsAlipay
  """

  @type t :: %__MODULE__{
          buyer_id: String.t() | nil,
          fingerprint: String.t() | nil,
          transaction_id: String.t() | nil
        }

  defstruct [:buyer_id, :fingerprint, :transaction_id]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [buyer_id: :string, fingerprint: :string, transaction_id: :string]
  end
end
