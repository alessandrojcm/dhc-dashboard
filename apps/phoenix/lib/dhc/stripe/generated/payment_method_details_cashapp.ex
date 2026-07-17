defmodule Dhc.Stripe.PaymentMethodDetailsCashapp do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsCashapp
  """

  @type t :: %__MODULE__{
          buyer_id: String.t() | nil,
          cashtag: String.t() | nil,
          transaction_id: String.t() | nil
        }

  defstruct [:buyer_id, :cashtag, :transaction_id]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [buyer_id: :string, cashtag: :string, transaction_id: :string]
  end
end
