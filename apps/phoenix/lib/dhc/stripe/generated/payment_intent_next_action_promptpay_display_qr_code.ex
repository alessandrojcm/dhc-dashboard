defmodule Dhc.Stripe.PaymentIntentNextActionPromptpayDisplayQrCode do
  @moduledoc """
  Provides struct and type for a PaymentIntentNextActionPromptpayDisplayQrCode
  """

  @type t :: %__MODULE__{
          data: String.t(),
          hosted_instructions_url: String.t(),
          image_url_png: String.t(),
          image_url_svg: String.t()
        }

  defstruct [:data, :hosted_instructions_url, :image_url_png, :image_url_svg]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      data: :string,
      hosted_instructions_url: :string,
      image_url_png: :string,
      image_url_svg: :string
    ]
  end
end
