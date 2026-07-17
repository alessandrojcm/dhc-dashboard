defmodule Dhc.Stripe.SetupIntentNextActionPixDisplayQrCode do
  @moduledoc """
  Provides struct and type for a SetupIntentNextActionPixDisplayQrCode
  """

  @type t :: %__MODULE__{
          data: String.t(),
          expires_at: integer,
          hosted_instructions_url: String.t(),
          image_url_png: String.t(),
          image_url_svg: String.t()
        }

  defstruct [:data, :expires_at, :hosted_instructions_url, :image_url_png, :image_url_svg]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      data: :string,
      expires_at: {:integer, "unix-time"},
      hosted_instructions_url: :string,
      image_url_png: :string,
      image_url_svg: :string
    ]
  end
end
