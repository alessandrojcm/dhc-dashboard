defmodule Dhc.Stripe.PaymentIntentNextActionUpiqrCode do
  @moduledoc """
  Provides struct and type for a PaymentIntentNextActionUpiqrCode
  """

  @type t :: %__MODULE__{
          expires_at: integer,
          image_url_png: String.t(),
          image_url_svg: String.t()
        }

  defstruct [:expires_at, :image_url_png, :image_url_svg]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [expires_at: {:integer, "unix-time"}, image_url_png: :string, image_url_svg: :string]
  end
end
