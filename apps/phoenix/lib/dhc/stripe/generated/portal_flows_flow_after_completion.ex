defmodule Dhc.Stripe.PortalFlowsFlowAfterCompletion do
  @moduledoc """
  Provides struct and type for a PortalFlowsFlowAfterCompletion
  """

  @type t :: %__MODULE__{
          hosted_confirmation: Dhc.Stripe.PortalFlowsAfterCompletionHostedConfirmation.t() | nil,
          redirect: Dhc.Stripe.PortalFlowsAfterCompletionRedirect.t() | nil,
          type: String.t()
        }

  defstruct [:hosted_confirmation, :redirect, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      hosted_confirmation: {Dhc.Stripe.PortalFlowsAfterCompletionHostedConfirmation, :t},
      redirect: {Dhc.Stripe.PortalFlowsAfterCompletionRedirect, :t},
      type: {:enum, ["hosted_confirmation", "portal_homepage", "redirect"]}
    ]
  end
end
