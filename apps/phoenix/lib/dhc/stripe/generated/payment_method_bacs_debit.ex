defmodule Dhc.Stripe.PaymentMethodBacsDebit do
  @moduledoc """
  Provides struct and type for a PaymentMethodBacsDebit
  """

  @type t :: %__MODULE__{
          fingerprint: String.t() | nil,
          last4: String.t() | nil,
          sort_code: String.t() | nil
        }

  defstruct [:fingerprint, :last4, :sort_code]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [fingerprint: :string, last4: :string, sort_code: :string]
  end
end
