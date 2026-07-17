defmodule Dhc.Stripe.PaymentIntentNextActionWechatPayRedirectToAndroidApp do
  @moduledoc """
  Provides struct and type for a PaymentIntentNextActionWechatPayRedirectToAndroidApp
  """

  @type t :: %__MODULE__{
          app_id: String.t(),
          nonce_str: String.t(),
          package: String.t(),
          partner_id: String.t(),
          prepay_id: String.t(),
          sign: String.t(),
          timestamp: String.t()
        }

  defstruct [:app_id, :nonce_str, :package, :partner_id, :prepay_id, :sign, :timestamp]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      app_id: :string,
      nonce_str: :string,
      package: :string,
      partner_id: :string,
      prepay_id: :string,
      sign: :string,
      timestamp: :string
    ]
  end
end
