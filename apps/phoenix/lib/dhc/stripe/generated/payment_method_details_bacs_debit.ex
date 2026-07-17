defmodule Dhc.Stripe.PaymentMethodDetailsBacsDebit do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsBacsDebit
  """

  @type t :: %__MODULE__{
          expected_debit_date: String.t() | nil,
          fingerprint: String.t() | nil,
          last4: String.t() | nil,
          mandate: String.t() | nil,
          sort_code: String.t() | nil
        }

  defstruct [:expected_debit_date, :fingerprint, :last4, :mandate, :sort_code]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      expected_debit_date: :string,
      fingerprint: :string,
      last4: :string,
      mandate: :string,
      sort_code: :string
    ]
  end
end
