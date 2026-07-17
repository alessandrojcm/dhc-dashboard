defmodule Dhc.Stripe.SubscriptionsTrialsResourceEndBehavior do
  @moduledoc """
  Provides struct and type for a SubscriptionsTrialsResourceEndBehavior
  """

  @type t :: %__MODULE__{missing_payment_method: String.t()}

  defstruct [:missing_payment_method]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [missing_payment_method: {:enum, ["cancel", "create_invoice", "pause"]}]
  end
end
