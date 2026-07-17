defmodule Dhc.Stripe.PaymentPagesCheckoutSessionCustomFieldsDropdown do
  @moduledoc """
  Provides struct and type for a PaymentPagesCheckoutSessionCustomFieldsDropdown
  """

  @type t :: %__MODULE__{
          default_value: String.t() | nil,
          options: [Dhc.Stripe.PaymentPagesCheckoutSessionCustomFieldsOption.t()],
          value: String.t() | nil
        }

  defstruct [:default_value, :options, :value]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      default_value: :string,
      options: [{Dhc.Stripe.PaymentPagesCheckoutSessionCustomFieldsOption, :t}],
      value: :string
    ]
  end
end
