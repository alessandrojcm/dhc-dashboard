defmodule Dhc.Stripe.SourceTypeAchCreditTransfer do
  @moduledoc """
  Provides struct and type for a SourceTypeAchCreditTransfer
  """

  @type t :: %__MODULE__{
          account_number: String.t() | nil,
          bank_name: String.t() | nil,
          fingerprint: String.t() | nil,
          refund_account_holder_name: String.t() | nil,
          refund_account_holder_type: String.t() | nil,
          refund_routing_number: String.t() | nil,
          routing_number: String.t() | nil,
          swift_code: String.t() | nil
        }

  defstruct [
    :account_number,
    :bank_name,
    :fingerprint,
    :refund_account_holder_name,
    :refund_account_holder_type,
    :refund_routing_number,
    :routing_number,
    :swift_code
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      account_number: :string,
      bank_name: :string,
      fingerprint: :string,
      refund_account_holder_name: :string,
      refund_account_holder_type: :string,
      refund_routing_number: :string,
      routing_number: :string,
      swift_code: :string
    ]
  end
end
