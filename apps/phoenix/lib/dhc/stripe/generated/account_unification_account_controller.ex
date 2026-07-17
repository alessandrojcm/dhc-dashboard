defmodule Dhc.Stripe.AccountUnificationAccountController do
  @moduledoc """
  Provides struct and type for a AccountUnificationAccountController
  """

  @type t :: %__MODULE__{
          fees: Dhc.Stripe.AccountUnificationAccountControllerFees.t() | nil,
          is_controller: boolean | nil,
          losses: Dhc.Stripe.AccountUnificationAccountControllerLosses.t() | nil,
          requirement_collection: String.t() | nil,
          stripe_dashboard:
            Dhc.Stripe.AccountUnificationAccountControllerStripeDashboard.t() | nil,
          type: String.t()
        }

  defstruct [:fees, :is_controller, :losses, :requirement_collection, :stripe_dashboard, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      fees: {Dhc.Stripe.AccountUnificationAccountControllerFees, :t},
      is_controller: :boolean,
      losses: {Dhc.Stripe.AccountUnificationAccountControllerLosses, :t},
      requirement_collection: {:enum, ["application", "stripe"]},
      stripe_dashboard: {Dhc.Stripe.AccountUnificationAccountControllerStripeDashboard, :t},
      type: {:enum, ["account", "application"]}
    ]
  end
end
