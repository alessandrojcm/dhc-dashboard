defmodule Dhc.Stripe.ScheduleDetailsParams do
  @moduledoc """
  Provides struct and type for a ScheduleDetailsParams
  """

  @type t :: %__MODULE__{
          billing_mode: Dhc.Stripe.BillingMode.t() | nil,
          end_behavior: String.t() | nil,
          phases: [Dhc.Stripe.PhaseConfigurationParams.t()] | nil,
          proration_behavior: String.t() | nil
        }

  defstruct [:billing_mode, :end_behavior, :phases, :proration_behavior]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      billing_mode: {Dhc.Stripe.BillingMode, :t},
      end_behavior: {:enum, ["cancel", "release"]},
      phases: [{Dhc.Stripe.PhaseConfigurationParams, :t}],
      proration_behavior: {:enum, ["always_invoice", "create_prorations", "none"]}
    ]
  end
end
