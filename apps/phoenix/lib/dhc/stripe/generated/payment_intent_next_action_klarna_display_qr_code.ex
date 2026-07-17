defmodule Dhc.Stripe.PaymentIntentNextActionKlarnaDisplayQrCode do
  @moduledoc """
  Provides struct and type for a PaymentIntentNextActionKlarnaDisplayQrCode
  """

  @type t :: %__MODULE__{
          data: String.t(),
          expires_at: integer | nil,
          image_url_png: String.t(),
          image_url_svg: String.t()
        }

  defstruct [:data, :expires_at, :image_url_png, :image_url_svg]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      data: :string,
      expires_at: {:integer, "unix-time"},
      image_url_png: :string,
      image_url_svg: :string
    ]
  end
end
