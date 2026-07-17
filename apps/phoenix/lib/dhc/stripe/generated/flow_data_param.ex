defmodule Dhc.Stripe.FlowDataParam do
  @moduledoc """
  Provides struct and type for a FlowDataParam
  """

  @type t :: %__MODULE__{
          after_completion: Dhc.Stripe.FlowDataAfterCompletionParam.t() | nil,
          subscription_cancel: Dhc.Stripe.FlowDataSubscriptionCancelParam.t() | nil,
          subscription_update: Dhc.Stripe.FlowDataSubscriptionUpdateParam.t() | nil,
          subscription_update_confirm:
            Dhc.Stripe.FlowDataSubscriptionUpdateConfirmParam.t() | nil,
          type: String.t()
        }

  defstruct [
    :after_completion,
    :subscription_cancel,
    :subscription_update,
    :subscription_update_confirm,
    :type
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      after_completion: {Dhc.Stripe.FlowDataAfterCompletionParam, :t},
      subscription_cancel: {Dhc.Stripe.FlowDataSubscriptionCancelParam, :t},
      subscription_update: {Dhc.Stripe.FlowDataSubscriptionUpdateParam, :t},
      subscription_update_confirm: {Dhc.Stripe.FlowDataSubscriptionUpdateConfirmParam, :t},
      type:
        {:enum,
         [
           "payment_method_update",
           "subscription_cancel",
           "subscription_update",
           "subscription_update_confirm"
         ]}
    ]
  end
end
