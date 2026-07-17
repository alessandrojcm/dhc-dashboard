defmodule Dhc.Stripe.PaymentIntentNextActionRedirectToUrl do
  @moduledoc """
  Provides struct and type for a PaymentIntentNextActionRedirectToUrl
  """

  @type t :: %__MODULE__{return_url: String.t() | nil, url: String.t() | nil}

  defstruct [:return_url, :url]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [return_url: :string, url: :string]
  end
end
