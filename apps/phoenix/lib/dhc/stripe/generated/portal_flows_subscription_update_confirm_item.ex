defmodule Dhc.Stripe.PortalFlowsSubscriptionUpdateConfirmItem do
  @moduledoc """
  Provides struct and type for a PortalFlowsSubscriptionUpdateConfirmItem
  """

  @type t :: %__MODULE__{id: String.t() | nil, price: String.t() | nil, quantity: integer | nil}

  defstruct [:id, :price, :quantity]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [id: :string, price: :string, quantity: :integer]
  end
end
