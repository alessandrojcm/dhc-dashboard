defmodule Dhc.Stripe.PaymentMethodOptionsPix do
  @moduledoc """
  Provides struct and type for a PaymentMethodOptionsPix
  """

  @type t :: %__MODULE__{
          amount_includes_iof: String.t() | nil,
          expires_after_seconds: integer | nil,
          expires_at: integer | nil,
          mandate_options: Dhc.Stripe.PaymentMethodOptionsMandateOptionsPix.t() | nil,
          setup_future_usage: String.t() | nil
        }

  defstruct [
    :amount_includes_iof,
    :expires_after_seconds,
    :expires_at,
    :mandate_options,
    :setup_future_usage
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount_includes_iof: {:enum, ["always", "never"]},
      expires_after_seconds: :integer,
      expires_at: :integer,
      mandate_options: {Dhc.Stripe.PaymentMethodOptionsMandateOptionsPix, :t},
      setup_future_usage: {:enum, ["none", "off_session"]}
    ]
  end
end
