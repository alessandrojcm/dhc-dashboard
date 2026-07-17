defmodule Dhc.Stripe.SetupAttempt do
  @moduledoc """
  Provides struct and type for a SetupAttempt
  """

  @type t :: %__MODULE__{
          application: Dhc.Stripe.Application.t() | String.t() | nil,
          attach_to_self: boolean | nil,
          created: integer,
          customer: Dhc.Stripe.Customer.t() | Dhc.Stripe.DeletedCustomer.t() | String.t() | nil,
          customer_account: String.t() | nil,
          flow_directions: [String.t()] | nil,
          id: String.t(),
          livemode: boolean,
          object: String.t(),
          on_behalf_of: Dhc.Stripe.Account.t() | String.t() | nil,
          payment_method: Dhc.Stripe.PaymentMethod.t() | String.t(),
          payment_method_details: Dhc.Stripe.SetupAttemptPaymentMethodDetails.t(),
          setup_error: Dhc.Stripe.ApiErrors.t() | nil,
          setup_intent: Dhc.Stripe.SetupIntent.t() | String.t(),
          status: String.t(),
          usage: String.t()
        }

  defstruct [
    :application,
    :attach_to_self,
    :created,
    :customer,
    :customer_account,
    :flow_directions,
    :id,
    :livemode,
    :object,
    :on_behalf_of,
    :payment_method,
    :payment_method_details,
    :setup_error,
    :setup_intent,
    :status,
    :usage
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      application: {:union, [:string, {Dhc.Stripe.Application, :t}]},
      attach_to_self: :boolean,
      created: {:integer, "unix-time"},
      customer: {:union, [:string, {Dhc.Stripe.Customer, :t}, {Dhc.Stripe.DeletedCustomer, :t}]},
      customer_account: :string,
      flow_directions: [enum: ["inbound", "outbound"]],
      id: :string,
      livemode: :boolean,
      object: {:const, "setup_attempt"},
      on_behalf_of: {:union, [:string, {Dhc.Stripe.Account, :t}]},
      payment_method: {:union, [:string, {Dhc.Stripe.PaymentMethod, :t}]},
      payment_method_details: {Dhc.Stripe.SetupAttemptPaymentMethodDetails, :t},
      setup_error: {Dhc.Stripe.ApiErrors, :t},
      setup_intent: {:union, [:string, {Dhc.Stripe.SetupIntent, :t}]},
      status: :string,
      usage: :string
    ]
  end
end
