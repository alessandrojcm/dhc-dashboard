defmodule Dhc.Stripe.PortalFlowsFlow do
  @moduledoc """
  Provides struct and type for a PortalFlowsFlow
  """

  @type t :: %__MODULE__{
          after_completion: Dhc.Stripe.PortalFlowsFlowAfterCompletion.t(),
          subscription_cancel: Dhc.Stripe.PortalFlowsFlowSubscriptionCancel.t() | nil,
          subscription_update: Dhc.Stripe.PortalFlowsFlowSubscriptionUpdate.t() | nil,
          subscription_update_confirm:
            Dhc.Stripe.PortalFlowsFlowSubscriptionUpdateConfirm.t() | nil,
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
      after_completion: {Dhc.Stripe.PortalFlowsFlowAfterCompletion, :t},
      subscription_cancel: {Dhc.Stripe.PortalFlowsFlowSubscriptionCancel, :t},
      subscription_update: {Dhc.Stripe.PortalFlowsFlowSubscriptionUpdate, :t},
      subscription_update_confirm: {Dhc.Stripe.PortalFlowsFlowSubscriptionUpdateConfirm, :t},
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
