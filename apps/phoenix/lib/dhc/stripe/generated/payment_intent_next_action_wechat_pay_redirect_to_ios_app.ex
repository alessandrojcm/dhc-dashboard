defmodule Dhc.Stripe.PaymentIntentNextActionWechatPayRedirectToIosApp do
  @moduledoc """
  Provides struct and type for a PaymentIntentNextActionWechatPayRedirectToIosApp
  """

  @type t :: %__MODULE__{native_url: String.t()}

  defstruct [:native_url]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [native_url: :string]
  end
end
