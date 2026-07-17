defmodule Dhc.Stripe.InvoicePaymentMethodOptionsCard do
  @moduledoc """
  Provides struct and type for a InvoicePaymentMethodOptionsCard
  """

  @type t :: %__MODULE__{
          installments: Dhc.Stripe.InvoiceInstallmentsCard.t() | nil,
          request_three_d_secure: String.t() | nil
        }

  defstruct [:installments, :request_three_d_secure]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      installments: {Dhc.Stripe.InvoiceInstallmentsCard, :t},
      request_three_d_secure: {:enum, ["any", "automatic", "challenge"]}
    ]
  end
end
