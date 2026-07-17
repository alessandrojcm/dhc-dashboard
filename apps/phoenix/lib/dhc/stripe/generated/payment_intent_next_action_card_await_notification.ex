defmodule Dhc.Stripe.PaymentIntentNextActionCardAwaitNotification do
  @moduledoc """
  Provides struct and type for a PaymentIntentNextActionCardAwaitNotification
  """

  @type t :: %__MODULE__{
          charge_attempt_at: integer | nil,
          customer_approval_required: boolean | nil
        }

  defstruct [:charge_attempt_at, :customer_approval_required]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [charge_attempt_at: {:integer, "unix-time"}, customer_approval_required: :boolean]
  end
end
