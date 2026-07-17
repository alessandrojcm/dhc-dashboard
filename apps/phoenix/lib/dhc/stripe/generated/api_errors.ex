defmodule Dhc.Stripe.ApiErrors do
  @moduledoc """
  Provides struct and type for a ApiErrors
  """

  @type t :: %__MODULE__{
          advice_code: String.t() | nil,
          charge: String.t() | nil,
          code: String.t() | nil,
          decline_code: String.t() | nil,
          doc_url: String.t() | nil,
          message: String.t() | nil,
          network_advice_code: String.t() | nil,
          network_decline_code: String.t() | nil,
          param: String.t() | nil,
          payment_intent: Dhc.Stripe.PaymentIntent.t() | nil,
          payment_method: Dhc.Stripe.PaymentMethod.t() | nil,
          payment_method_type: String.t() | nil,
          request_log_url: String.t() | nil,
          setup_intent: Dhc.Stripe.SetupIntent.t() | nil,
          source: Dhc.Stripe.BankAccount.t() | Dhc.Stripe.Card.t() | Dhc.Stripe.Source.t() | nil,
          type: String.t()
        }

  defstruct [
    :advice_code,
    :charge,
    :code,
    :decline_code,
    :doc_url,
    :message,
    :network_advice_code,
    :network_decline_code,
    :param,
    :payment_intent,
    :payment_method,
    :payment_method_type,
    :request_log_url,
    :setup_intent,
    :source,
    :type
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      advice_code: :string,
      charge: :string,
      code: :string,
      decline_code: :string,
      doc_url: :string,
      message: :string,
      network_advice_code: :string,
      network_decline_code: :string,
      param: :string,
      payment_intent: {Dhc.Stripe.PaymentIntent, :t},
      payment_method: {Dhc.Stripe.PaymentMethod, :t},
      payment_method_type: :string,
      request_log_url: :string,
      setup_intent: {Dhc.Stripe.SetupIntent, :t},
      source:
        {:union, [{Dhc.Stripe.BankAccount, :t}, {Dhc.Stripe.Card, :t}, {Dhc.Stripe.Source, :t}]},
      type: {:enum, ["api_error", "card_error", "idempotency_error", "invalid_request_error"]}
    ]
  end
end
