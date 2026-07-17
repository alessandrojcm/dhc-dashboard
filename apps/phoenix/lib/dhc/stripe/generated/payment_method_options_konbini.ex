defmodule Dhc.Stripe.PaymentMethodOptionsKonbini do
  @moduledoc """
  Provides struct and type for a PaymentMethodOptionsKonbini
  """

  @type t :: %__MODULE__{
          confirmation_number: String.t() | nil,
          expires_after_days: integer | nil,
          expires_at: integer | nil,
          product_description: String.t() | nil,
          setup_future_usage: String.t() | nil
        }

  defstruct [
    :confirmation_number,
    :expires_after_days,
    :expires_at,
    :product_description,
    :setup_future_usage
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      confirmation_number: :string,
      expires_after_days: :integer,
      expires_at: {:integer, "unix-time"},
      product_description: :string,
      setup_future_usage: {:const, "none"}
    ]
  end
end
