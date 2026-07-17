defmodule Dhc.Stripe.SourceReceiverFlow do
  @moduledoc """
  Provides struct and type for a SourceReceiverFlow
  """

  @type t :: %__MODULE__{
          address: String.t() | nil,
          amount_charged: integer,
          amount_received: integer,
          amount_returned: integer,
          refund_attributes_method: String.t(),
          refund_attributes_status: String.t()
        }

  defstruct [
    :address,
    :amount_charged,
    :amount_received,
    :amount_returned,
    :refund_attributes_method,
    :refund_attributes_status
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      address: :string,
      amount_charged: :integer,
      amount_received: :integer,
      amount_returned: :integer,
      refund_attributes_method: :string,
      refund_attributes_status: :string
    ]
  end
end
