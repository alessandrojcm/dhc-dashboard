defmodule Dhc.Stripe.PaymentMethodParam do
  @moduledoc """
  Provides struct and types for a PaymentMethodParam
  """

  @type t :: %__MODULE__{
          account_holder_type: String.t() | nil,
          account_number: String.t() | nil,
          account_type: String.t() | nil,
          financial_connections_account: String.t() | nil,
          institution_number: String.t(),
          routing_number: String.t() | nil,
          transit_number: String.t()
        }

  defstruct [
    :account_holder_type,
    :account_number,
    :account_type,
    :financial_connections_account,
    :institution_number,
    :routing_number,
    :transit_number
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      account_holder_type: {:enum, ["company", "individual"]},
      account_number: :string,
      account_type: {:enum, ["checking", "savings"]},
      financial_connections_account: :string,
      institution_number: :string,
      routing_number: :string,
      transit_number: :string
    ]
  end
end
