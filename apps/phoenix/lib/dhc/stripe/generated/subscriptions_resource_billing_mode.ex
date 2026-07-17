defmodule Dhc.Stripe.SubscriptionsResourceBillingMode do
  @moduledoc """
  Provides struct and type for a SubscriptionsResourceBillingMode
  """

  @type t :: %__MODULE__{
          flexible: Dhc.Stripe.SubscriptionsResourceBillingModeFlexible.t() | nil,
          type: String.t(),
          updated_at: integer | nil
        }

  defstruct [:flexible, :type, :updated_at]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      flexible: {Dhc.Stripe.SubscriptionsResourceBillingModeFlexible, :t},
      type: {:enum, ["classic", "flexible"]},
      updated_at: {:integer, "unix-time"}
    ]
  end
end
