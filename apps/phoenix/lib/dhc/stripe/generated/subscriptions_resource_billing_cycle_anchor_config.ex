defmodule Dhc.Stripe.SubscriptionsResourceBillingCycleAnchorConfig do
  @moduledoc """
  Provides struct and type for a SubscriptionsResourceBillingCycleAnchorConfig
  """

  @type t :: %__MODULE__{
          day_of_month: integer,
          hour: integer | nil,
          minute: integer | nil,
          month: integer | nil,
          second: integer | nil
        }

  defstruct [:day_of_month, :hour, :minute, :month, :second]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [day_of_month: :integer, hour: :integer, minute: :integer, month: :integer, second: :integer]
  end
end
