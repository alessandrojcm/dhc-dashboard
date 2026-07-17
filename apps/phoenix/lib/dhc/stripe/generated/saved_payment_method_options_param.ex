defmodule Dhc.Stripe.SavedPaymentMethodOptionsParam do
  @moduledoc """
  Provides struct and type for a SavedPaymentMethodOptionsParam
  """

  @type t :: %__MODULE__{
          allow_redisplay_filters: [String.t()] | nil,
          payment_method_remove: String.t() | nil,
          payment_method_save: String.t() | nil
        }

  defstruct [:allow_redisplay_filters, :payment_method_remove, :payment_method_save]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      allow_redisplay_filters: [enum: ["always", "limited", "unspecified"]],
      payment_method_remove: {:enum, ["disabled", "enabled"]},
      payment_method_save: {:enum, ["disabled", "enabled"]}
    ]
  end
end
