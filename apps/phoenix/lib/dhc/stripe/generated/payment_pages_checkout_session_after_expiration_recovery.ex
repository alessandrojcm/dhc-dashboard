defmodule Dhc.Stripe.PaymentPagesCheckoutSessionAfterExpirationRecovery do
  @moduledoc """
  Provides struct and type for a PaymentPagesCheckoutSessionAfterExpirationRecovery
  """

  @type t :: %__MODULE__{
          allow_promotion_codes: boolean,
          enabled: boolean,
          expires_at: integer | nil,
          url: String.t() | nil
        }

  defstruct [:allow_promotion_codes, :enabled, :expires_at, :url]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      allow_promotion_codes: :boolean,
      enabled: :boolean,
      expires_at: {:integer, "unix-time"},
      url: :string
    ]
  end
end
