defmodule Dhc.Stripe.PaymentIntentNextActionCashappHandleRedirectOrDisplayQrCode do
  @moduledoc """
  Provides struct and type for a PaymentIntentNextActionCashappHandleRedirectOrDisplayQrCode
  """

  @type t :: %__MODULE__{
          hosted_instructions_url: String.t(),
          mobile_auth_url: String.t(),
          qr_code: Dhc.Stripe.PaymentIntentNextActionCashappQrCode.t()
        }

  defstruct [:hosted_instructions_url, :mobile_auth_url, :qr_code]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      hosted_instructions_url: :string,
      mobile_auth_url: :string,
      qr_code: {Dhc.Stripe.PaymentIntentNextActionCashappQrCode, :t}
    ]
  end
end
