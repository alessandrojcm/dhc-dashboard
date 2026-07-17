defmodule Dhc.Stripe.PaymentPagesCheckoutSessionPermissions do
  @moduledoc """
  Provides struct and type for a PaymentPagesCheckoutSessionPermissions
  """

  @type t :: %__MODULE__{update_shipping_details: String.t() | nil}

  defstruct [:update_shipping_details]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [update_shipping_details: {:enum, ["client_only", "server_only"]}]
  end
end
