defmodule Dhc.Stripe.BrandingSettingsParams do
  @moduledoc """
  Provides struct and type for a BrandingSettingsParams
  """

  @type t :: %__MODULE__{
          background_color: String.t() | nil,
          border_style: String.t() | nil,
          button_color: String.t() | nil,
          display_name: String.t() | nil,
          font_family: String.t() | nil,
          icon: Dhc.Stripe.IconParams.t() | nil,
          logo: Dhc.Stripe.LogoParams.t() | nil
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
      background_color: {:union, [:string, const: ""]},
      border_style: {:enum, ["", "pill", "rectangular", "rounded"]},
      button_color: {:union, [:string, const: ""]},
      display_name: :string,
      font_family:
        {:enum,
         [
           "",
           "be_vietnam_pro",
           "bitter",
           "chakra_petch",
           "default",
           "hahmlet",
           "inconsolata",
           "inter",
           "lato",
           "lora",
           "m_plus_1_code",
           "montserrat",
           "noto_sans",
           "noto_sans_jp",
           "noto_serif",
           "nunito",
           "open_sans",
           "pridi",
           "pt_sans",
           "pt_serif",
           "raleway",
           "roboto",
           "roboto_slab",
           "source_sans_pro",
           "titillium_web",
           "ubuntu_mono",
           "zen_maru_gothic"
         ]},
      icon: {Dhc.Stripe.IconParams, :t},
      logo: {Dhc.Stripe.LogoParams, :t}
    ]
  end
end
