defmodule Dhc.Stripe.PaymentIntentNextActionDisplayMultibancoDetails do
  @moduledoc """
  Provides struct and type for a PaymentIntentNextActionDisplayMultibancoDetails
  """

  @type t :: %__MODULE__{
          entity: String.t() | nil,
          expires_at: integer | nil,
          hosted_voucher_url: String.t() | nil,
          reference: String.t() | nil
        }

  defstruct [:entity, :expires_at, :hosted_voucher_url, :reference]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      entity: :string,
      expires_at: {:integer, "unix-time"},
      hosted_voucher_url: :string,
      reference: :string
    ]
  end
end
