defmodule Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceProcessorDetails do
  @moduledoc """
  Provides struct and type for a PaymentsPrimitivesPaymentRecordsResourceProcessorDetails
  """

  @type t :: %__MODULE__{
          custom:
            Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceProcessorDetailsResourceCustomDetails.t()
            | nil,
          type: String.t()
        }

  defstruct [:custom, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      custom:
        {Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceProcessorDetailsResourceCustomDetails,
         :t},
      type: {:const, "custom"}
    ]
  end
end
