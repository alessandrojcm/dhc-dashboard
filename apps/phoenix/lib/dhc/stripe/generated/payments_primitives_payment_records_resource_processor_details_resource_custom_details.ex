defmodule Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceProcessorDetailsResourceCustomDetails do
  @moduledoc """
  Provides struct and type for a PaymentsPrimitivesPaymentRecordsResourceProcessorDetailsResourceCustomDetails
  """

  @type t :: %__MODULE__{payment_reference: String.t() | nil}

  defstruct [:payment_reference]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [payment_reference: :string]
  end
end
