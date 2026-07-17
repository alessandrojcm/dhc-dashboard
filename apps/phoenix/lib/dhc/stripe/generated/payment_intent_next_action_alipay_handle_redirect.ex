defmodule Dhc.Stripe.PaymentIntentNextActionAlipayHandleRedirect do
  @moduledoc """
  Provides struct and type for a PaymentIntentNextActionAlipayHandleRedirect
  """

  @type t :: %__MODULE__{
          native_data: String.t() | nil,
          native_url: String.t() | nil,
          return_url: String.t() | nil,
          url: String.t() | nil
        }

  defstruct [:native_data, :native_url, :return_url, :url]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [native_data: :string, native_url: :string, return_url: :string, url: :string]
  end
end
