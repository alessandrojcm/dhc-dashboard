defmodule Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodCustomDetails do
  @moduledoc """
  Provides struct and type for a PaymentsPrimitivesPaymentRecordsResourcePaymentMethodCustomDetails
  """

  @type t :: %__MODULE__{display_name: String.t(), type: String.t() | nil}

  defstruct [:display_name, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [display_name: :string, type: :string]
  end
end
