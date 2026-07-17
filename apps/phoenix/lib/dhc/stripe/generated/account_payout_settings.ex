defmodule Dhc.Stripe.AccountPayoutSettings do
  @moduledoc """
  Provides struct and type for a AccountPayoutSettings
  """

  @type t :: %__MODULE__{
          debit_negative_balances: boolean,
          schedule: Dhc.Stripe.TransferSchedule.t(),
          statement_descriptor: String.t() | nil
        }

  defstruct [:debit_negative_balances, :schedule, :statement_descriptor]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      debit_negative_balances: :boolean,
      schedule: {Dhc.Stripe.TransferSchedule, :t},
      statement_descriptor: :string
    ]
  end
end
