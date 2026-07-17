defmodule Dhc.Stripe.PaymentMethodDetailsWechatPay do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsWechatPay
  """

  @type t :: %__MODULE__{
          fingerprint: String.t() | nil,
          location: String.t() | nil,
          reader: String.t() | nil,
          transaction_id: String.t() | nil
        }

  defstruct [:fingerprint, :location, :reader, :transaction_id]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [fingerprint: :string, location: :string, reader: :string, transaction_id: :string]
  end
end
