defmodule Dhc.Stripe.PaymentRecordRefundParams do
  @moduledoc """
  Provides struct and type for a PaymentRecordRefundParams
  """

  @type t :: %__MODULE__{payment_record: String.t(), refund_group: String.t()}

  defstruct [:payment_record, :refund_group]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [payment_record: :string, refund_group: :string]
  end
end
