defmodule Dhc.Stripe.PaymentIntentNextActionPixDisplayQrCode do
  @moduledoc """
  Provides struct and type for a PaymentIntentNextActionPixDisplayQrCode
  """

  @type t :: %__MODULE__{
          data: String.t() | nil,
          expires_at: integer | nil,
          hosted_instructions_url: String.t() | nil,
          image_url_png: String.t() | nil,
          image_url_svg: String.t() | nil
        }

  defstruct [:data, :expires_at, :hosted_instructions_url, :image_url_png, :image_url_svg]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      data: :string,
      expires_at: :integer,
      hosted_instructions_url: :string,
      image_url_png: :string,
      image_url_svg: :string
    ]
  end
end
