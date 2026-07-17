defmodule Dhc.Stripe.PaymentMethodDetailsKlarna do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsKlarna
  """

  @type t :: %__MODULE__{
          location: String.t() | nil,
          payer_details: Dhc.Stripe.KlarnaPayerDetails.t() | nil,
          payment_method_category: String.t() | nil,
          preferred_locale: String.t() | nil,
          reader: String.t() | nil
        }

  defstruct [:location, :payer_details, :payment_method_category, :preferred_locale, :reader]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      location: :string,
      payer_details: {Dhc.Stripe.KlarnaPayerDetails, :t},
      payment_method_category: :string,
      preferred_locale: :string,
      reader: :string
    ]
  end
end
