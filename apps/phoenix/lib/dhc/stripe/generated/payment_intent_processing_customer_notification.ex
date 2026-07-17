defmodule Dhc.Stripe.PaymentIntentProcessingCustomerNotification do
  @moduledoc """
  Provides struct and type for a PaymentIntentProcessingCustomerNotification
  """

  @type t :: %__MODULE__{approval_requested: boolean | nil, completes_at: integer | nil}

  defstruct [:approval_requested, :completes_at]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [approval_requested: :boolean, completes_at: {:integer, "unix-time"}]
  end
end
