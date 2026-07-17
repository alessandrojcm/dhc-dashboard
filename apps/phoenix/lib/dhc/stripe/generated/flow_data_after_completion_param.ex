defmodule Dhc.Stripe.FlowDataAfterCompletionParam do
  @moduledoc """
  Provides struct and type for a FlowDataAfterCompletionParam
  """

  @type t :: %__MODULE__{
          hosted_confirmation: Dhc.Stripe.AfterCompletionHostedConfirmationParam.t() | nil,
          redirect: Dhc.Stripe.AfterCompletionRedirectParam.t() | nil,
          type: String.t()
        }

  defstruct [:hosted_confirmation, :redirect, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      hosted_confirmation: {Dhc.Stripe.AfterCompletionHostedConfirmationParam, :t},
      redirect: {Dhc.Stripe.AfterCompletionRedirectParam, :t},
      type: {:enum, ["hosted_confirmation", "portal_homepage", "redirect"]}
    ]
  end
end
