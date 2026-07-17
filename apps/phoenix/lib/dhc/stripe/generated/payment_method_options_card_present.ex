defmodule Dhc.Stripe.PaymentMethodOptionsCardPresent do
  @moduledoc """
  Provides struct and type for a PaymentMethodOptionsCardPresent
  """

  @type t :: %__MODULE__{
          capture_method: String.t() | nil,
          request_extended_authorization: boolean | nil,
          request_incremental_authorization_support: boolean | nil,
          routing: Dhc.Stripe.PaymentMethodOptionsCardPresentRouting.t() | nil
        }

  defstruct [
    :capture_method,
    :request_extended_authorization,
    :request_incremental_authorization_support,
    :routing
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      capture_method: {:enum, ["manual", "manual_preferred"]},
      request_extended_authorization: :boolean,
      request_incremental_authorization_support: :boolean,
      routing: {Dhc.Stripe.PaymentMethodOptionsCardPresentRouting, :t}
    ]
  end
end
