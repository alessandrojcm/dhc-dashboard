defmodule Dhc.Stripe.PaymentIntentNextActionBoleto do
  @moduledoc """
  Provides struct and type for a PaymentIntentNextActionBoleto
  """

  @type t :: %__MODULE__{
          expires_at: integer | nil,
          hosted_voucher_url: String.t() | nil,
          number: String.t() | nil,
          pdf: String.t() | nil
        }

  defstruct [:expires_at, :hosted_voucher_url, :number, :pdf]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      expires_at: {:integer, "unix-time"},
      hosted_voucher_url: :string,
      number: :string,
      pdf: :string
    ]
  end
end
