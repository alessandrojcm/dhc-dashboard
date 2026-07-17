defmodule Dhc.Stripe.PaymentMethodCustom do
  @moduledoc """
  Provides struct and type for a PaymentMethodCustom
  """

  @type t :: %__MODULE__{
          display_name: String.t() | nil,
          logo: Dhc.Stripe.CustomLogo.t() | nil,
          type: String.t()
        }

  defstruct [:display_name, :logo, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [display_name: :string, logo: {Dhc.Stripe.CustomLogo, :t}, type: :string]
  end
end
