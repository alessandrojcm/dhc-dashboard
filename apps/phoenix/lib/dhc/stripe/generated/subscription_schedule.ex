defmodule Dhc.Stripe.SubscriptionSchedule do
  @moduledoc """
  Provides struct and type for a SubscriptionSchedule
  """

  @type t :: %__MODULE__{
          application:
            Dhc.Stripe.Application.t() | Dhc.Stripe.DeletedApplication.t() | String.t() | nil,
          billing_mode: Dhc.Stripe.SubscriptionsResourceBillingMode.t(),
          canceled_at: integer | nil,
          completed_at: integer | nil,
          created: integer,
          current_phase: Dhc.Stripe.SubscriptionScheduleCurrentPhase.t() | nil,
          customer: Dhc.Stripe.Customer.t() | Dhc.Stripe.DeletedCustomer.t() | String.t(),
          customer_account: String.t() | nil,
          default_settings: Dhc.Stripe.SubscriptionSchedulesResourceDefaultSettings.t(),
          end_behavior: String.t(),
          id: String.t(),
          livemode: boolean,
          metadata: map | nil,
          object: String.t(),
          phases: [Dhc.Stripe.SubscriptionSchedulePhaseConfiguration.t()],
          released_at: integer | nil,
          released_subscription: String.t() | nil,
          status: String.t(),
          subscription: Dhc.Stripe.Subscription.t() | String.t() | nil,
          test_clock: Dhc.Stripe.TestHelpersTestClock.t() | String.t() | nil
        }

  defstruct [
    :application,
    :billing_mode,
    :canceled_at,
    :completed_at,
    :created,
    :current_phase,
    :customer,
    :customer_account,
    :default_settings,
    :end_behavior,
    :id,
    :livemode,
    :metadata,
    :object,
    :phases,
    :released_at,
    :released_subscription,
    :status,
    :subscription,
    :test_clock
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      application:
        {:union, [:string, {Dhc.Stripe.Application, :t}, {Dhc.Stripe.DeletedApplication, :t}]},
      billing_mode: {Dhc.Stripe.SubscriptionsResourceBillingMode, :t},
      canceled_at: {:integer, "unix-time"},
      completed_at: {:integer, "unix-time"},
      created: {:integer, "unix-time"},
      current_phase: {Dhc.Stripe.SubscriptionScheduleCurrentPhase, :t},
      customer: {:union, [:string, {Dhc.Stripe.Customer, :t}, {Dhc.Stripe.DeletedCustomer, :t}]},
      customer_account: :string,
      default_settings: {Dhc.Stripe.SubscriptionSchedulesResourceDefaultSettings, :t},
      end_behavior: {:enum, ["cancel", "none", "release", "renew"]},
      id: :string,
      livemode: :boolean,
      metadata: :map,
      object: {:const, "subscription_schedule"},
      phases: [{Dhc.Stripe.SubscriptionSchedulePhaseConfiguration, :t}],
      released_at: {:integer, "unix-time"},
      released_subscription: :string,
      status: {:enum, ["active", "canceled", "completed", "not_started", "released"]},
      subscription: {:union, [:string, {Dhc.Stripe.Subscription, :t}]},
      test_clock: {:union, [:string, {Dhc.Stripe.TestHelpersTestClock, :t}]}
    ]
  end
end
