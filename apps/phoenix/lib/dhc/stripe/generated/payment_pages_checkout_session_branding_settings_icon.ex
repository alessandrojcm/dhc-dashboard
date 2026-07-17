defmodule Dhc.Stripe.PaymentPagesCheckoutSessionBrandingSettingsIcon do
  @moduledoc """
  Provides struct and type for a PaymentPagesCheckoutSessionBrandingSettingsIcon
  """

  @type t :: %__MODULE__{file: String.t() | nil, type: String.t(), url: String.t() | nil}

  defstruct [:file, :type, :url]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [file: :string, type: {:enum, ["file", "url"]}, url: :string]
  end
end
