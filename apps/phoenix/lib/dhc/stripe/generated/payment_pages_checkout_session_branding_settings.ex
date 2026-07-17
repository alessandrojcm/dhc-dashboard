defmodule Dhc.Stripe.PaymentPagesCheckoutSessionBrandingSettings do
  @moduledoc """
  Provides struct and type for a PaymentPagesCheckoutSessionBrandingSettings
  """

  @type t :: %__MODULE__{
          background_color: String.t(),
          border_style: String.t(),
          button_color: String.t(),
          display_name: String.t(),
          font_family: String.t(),
          icon: Dhc.Stripe.PaymentPagesCheckoutSessionBrandingSettingsIcon.t() | nil,
          logo: Dhc.Stripe.PaymentPagesCheckoutSessionBrandingSettingsLogo.t() | nil
        }

  defstruct [
    :background_color,
    :border_style,
    :button_color,
    :display_name,
    :font_family,
    :icon,
    :logo
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      background_color: :string,
      border_style: {:enum, ["pill", "rectangular", "rounded"]},
      button_color: :string,
      display_name: :string,
      font_family: :string,
      icon: {Dhc.Stripe.PaymentPagesCheckoutSessionBrandingSettingsIcon, :t},
      logo: {Dhc.Stripe.PaymentPagesCheckoutSessionBrandingSettingsLogo, :t}
    ]
  end
end
