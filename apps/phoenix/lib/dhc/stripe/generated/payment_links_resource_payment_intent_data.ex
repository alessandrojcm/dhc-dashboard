defmodule Dhc.Stripe.PaymentLinksResourcePaymentIntentData do
  @moduledoc """
  Provides struct and type for a PaymentLinksResourcePaymentIntentData
  """

  @type t :: %__MODULE__{
          capture_method: String.t() | nil,
          description: String.t() | nil,
          metadata: map,
          setup_future_usage: String.t() | nil,
          statement_descriptor: String.t() | nil,
          statement_descriptor_suffix: String.t() | nil,
          transfer_group: String.t() | nil
        }

  defstruct [
    :capture_method,
    :description,
    :metadata,
    :setup_future_usage,
    :statement_descriptor,
    :statement_descriptor_suffix,
    :transfer_group
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      capture_method: {:enum, ["automatic", "automatic_async", "manual"]},
      description: :string,
      metadata: :map,
      setup_future_usage: {:enum, ["off_session", "on_session"]},
      statement_descriptor: :string,
      statement_descriptor_suffix: :string,
      transfer_group: :string
    ]
  end
end
