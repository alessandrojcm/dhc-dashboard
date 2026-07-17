defmodule Dhc.Stripe.PortalPaymentMethodUpdate do
  @moduledoc """
  Provides struct and type for a PortalPaymentMethodUpdate
  """

  @type t :: %__MODULE__{enabled: boolean, payment_method_configuration: String.t() | nil}

  defstruct [:enabled, :payment_method_configuration]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [enabled: :boolean, payment_method_configuration: :string]
  end
end
