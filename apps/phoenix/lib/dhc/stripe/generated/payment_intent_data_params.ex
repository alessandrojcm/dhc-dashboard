defmodule Dhc.Stripe.PaymentIntentDataParams do
  @moduledoc """
  Provides struct and type for a PaymentIntentDataParams
  """

  @type t :: %__MODULE__{
          application_fee_amount: integer | nil,
          capture_method: String.t() | nil,
          description: String.t() | nil,
          metadata: map | nil,
          on_behalf_of: String.t() | nil,
          receipt_email: String.t() | nil,
          setup_future_usage: String.t() | nil,
          shipping: Dhc.Stripe.Shipping.t() | nil,
          statement_descriptor: String.t() | nil,
          statement_descriptor_suffix: String.t() | nil,
          transfer_data: Dhc.Stripe.TransferDataParams.t() | nil,
          transfer_group: String.t() | nil
        }

  defstruct [
    :application_fee_amount,
    :capture_method,
    :description,
    :metadata,
    :on_behalf_of,
    :receipt_email,
    :setup_future_usage,
    :shipping,
    :statement_descriptor,
    :statement_descriptor_suffix,
    :transfer_data,
    :transfer_group
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      application_fee_amount: :integer,
      capture_method: {:enum, ["automatic", "automatic_async", "manual"]},
      description: :string,
      metadata: :map,
      on_behalf_of: :string,
      receipt_email: :string,
      setup_future_usage: {:enum, ["off_session", "on_session"]},
      shipping: {Dhc.Stripe.Shipping, :t},
      statement_descriptor: :string,
      statement_descriptor_suffix: :string,
      transfer_data: {Dhc.Stripe.TransferDataParams, :t},
      transfer_group: :string
    ]
  end
end
