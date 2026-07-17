defmodule Dhc.Stripe.PaymentIntentNextActionUpiHandleRedirectOrDisplayQrCode do
  @moduledoc """
  Provides struct and type for a PaymentIntentNextActionUpiHandleRedirectOrDisplayQrCode
  """

  @type t :: %__MODULE__{
          hosted_instructions_url: String.t(),
          qr_code: Dhc.Stripe.PaymentIntentNextActionUpiqrCode.t()
        }

  defstruct [:hosted_instructions_url, :qr_code]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [hosted_instructions_url: :string, qr_code: {Dhc.Stripe.PaymentIntentNextActionUpiqrCode, :t}]
  end
end
