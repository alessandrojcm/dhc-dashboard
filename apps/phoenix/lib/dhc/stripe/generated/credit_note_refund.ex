defmodule Dhc.Stripe.CreditNoteRefund do
  @moduledoc """
  Provides struct and type for a CreditNoteRefund
  """

  @type t :: %__MODULE__{
          amount_refunded: integer,
          payment_record_refund: Dhc.Stripe.CreditNotesPaymentRecordRefund.t() | nil,
          refund: Dhc.Stripe.Refund.t() | String.t(),
          type: String.t() | nil
        }

  defstruct [:amount_refunded, :payment_record_refund, :refund, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount_refunded: :integer,
      payment_record_refund: {Dhc.Stripe.CreditNotesPaymentRecordRefund, :t},
      refund: {:union, [:string, {Dhc.Stripe.Refund, :t}]},
      type: {:enum, ["payment_record_refund", "refund"]}
    ]
  end
end
