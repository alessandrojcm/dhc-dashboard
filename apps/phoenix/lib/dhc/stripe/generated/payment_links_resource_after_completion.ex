defmodule Dhc.Stripe.PaymentLinksResourceAfterCompletion do
  @moduledoc """
  Provides struct and type for a PaymentLinksResourceAfterCompletion
  """

  @type t :: %__MODULE__{
          hosted_confirmation:
            Dhc.Stripe.PaymentLinksResourceCompletionBehaviorConfirmationPage.t() | nil,
          redirect: Dhc.Stripe.PaymentLinksResourceCompletionBehaviorRedirect.t() | nil,
          type: String.t()
        }

  defstruct [:hosted_confirmation, :redirect, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      hosted_confirmation:
        {Dhc.Stripe.PaymentLinksResourceCompletionBehaviorConfirmationPage, :t},
      redirect: {Dhc.Stripe.PaymentLinksResourceCompletionBehaviorRedirect, :t},
      type: {:enum, ["hosted_confirmation", "redirect"]}
    ]
  end
end
