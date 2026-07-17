defmodule Dhc.Stripe.IssuingTransactionNetworkData do
  @moduledoc """
  Provides struct and type for a IssuingTransactionNetworkData
  """

  @type t :: %__MODULE__{
          authorization_code: String.t() | nil,
          processing_date: String.t() | nil,
          transaction_id: String.t() | nil
        }

  defstruct [:authorization_code, :processing_date, :transaction_id]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [authorization_code: :string, processing_date: :string, transaction_id: :string]
  end
end
