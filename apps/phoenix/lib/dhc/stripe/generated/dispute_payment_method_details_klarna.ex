defmodule Dhc.Stripe.DisputePaymentMethodDetailsKlarna do
  @moduledoc """
  Provides struct and type for a DisputePaymentMethodDetailsKlarna
  """

  @type t :: %__MODULE__{
          chargeback_loss_reason_code: String.t() | nil,
          reason_code: String.t() | nil
        }

  defstruct [:chargeback_loss_reason_code, :reason_code]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [chargeback_loss_reason_code: :string, reason_code: :string]
  end
end
