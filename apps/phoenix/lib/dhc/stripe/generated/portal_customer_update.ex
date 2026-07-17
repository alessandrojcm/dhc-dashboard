defmodule Dhc.Stripe.PortalCustomerUpdate do
  @moduledoc """
  Provides struct and type for a PortalCustomerUpdate
  """

  @type t :: %__MODULE__{allowed_updates: [String.t()], enabled: boolean}

  defstruct [:allowed_updates, :enabled]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      allowed_updates: [enum: ["address", "email", "name", "phone", "shipping", "tax_id"]],
      enabled: :boolean
    ]
  end
end
