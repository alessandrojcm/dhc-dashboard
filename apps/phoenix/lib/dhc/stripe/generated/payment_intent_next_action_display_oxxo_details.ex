defmodule Dhc.Stripe.PaymentIntentNextActionDisplayOxxoDetails do
  @moduledoc """
  Provides struct and type for a PaymentIntentNextActionDisplayOxxoDetails
  """

  @type t :: %__MODULE__{
          expires_after: integer | nil,
          hosted_voucher_url: String.t() | nil,
          number: String.t() | nil
        }

  defstruct [:expires_after, :hosted_voucher_url, :number]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [expires_after: {:integer, "unix-time"}, hosted_voucher_url: :string, number: :string]
  end
end
