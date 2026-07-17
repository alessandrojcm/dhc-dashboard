defmodule Dhc.Stripe.SubscriptionsResourceSubscriptionPresentmentDetails do
  @moduledoc """
  Provides struct and type for a SubscriptionsResourceSubscriptionPresentmentDetails
  """

  @type t :: %__MODULE__{presentment_currency: String.t()}

  defstruct [:presentment_currency]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [presentment_currency: :string]
  end
end
