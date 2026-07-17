defmodule Dhc.Stripe.PaymentIntentNextActionSwishHandleRedirectOrDisplayQrCode do
  @moduledoc """
  Provides struct and type for a PaymentIntentNextActionSwishHandleRedirectOrDisplayQrCode
  """

  @type t :: %__MODULE__{
          hosted_instructions_url: String.t(),
          qr_code: Dhc.Stripe.PaymentIntentNextActionSwishQrCode.t()
        }

  defstruct [:hosted_instructions_url, :qr_code]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      hosted_instructions_url: :string,
      qr_code: {Dhc.Stripe.PaymentIntentNextActionSwishQrCode, :t}
    ]
  end
end
