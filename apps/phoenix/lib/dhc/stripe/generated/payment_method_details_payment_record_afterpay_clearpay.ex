defmodule Dhc.Stripe.PaymentMethodDetailsPaymentRecordAfterpayClearpay do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsPaymentRecordAfterpayClearpay
  """

  @type t :: %__MODULE__{order_id: String.t() | nil, reference: String.t() | nil}

  defstruct [:order_id, :reference]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [order_id: :string, reference: :string]
  end
end
