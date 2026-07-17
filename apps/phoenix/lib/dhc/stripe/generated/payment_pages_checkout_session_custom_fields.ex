defmodule Dhc.Stripe.PaymentPagesCheckoutSessionCustomFields do
  @moduledoc """
  Provides struct and type for a PaymentPagesCheckoutSessionCustomFields
  """

  @type t :: %__MODULE__{
          dropdown: Dhc.Stripe.PaymentPagesCheckoutSessionCustomFieldsDropdown.t() | nil,
          key: String.t(),
          label: Dhc.Stripe.PaymentPagesCheckoutSessionCustomFieldsLabel.t(),
          numeric: Dhc.Stripe.PaymentPagesCheckoutSessionCustomFieldsNumeric.t() | nil,
          optional: boolean,
          text: Dhc.Stripe.PaymentPagesCheckoutSessionCustomFieldsText.t() | nil,
          type: String.t()
        }

  defstruct [:dropdown, :key, :label, :numeric, :optional, :text, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      dropdown: {Dhc.Stripe.PaymentPagesCheckoutSessionCustomFieldsDropdown, :t},
      key: :string,
      label: {Dhc.Stripe.PaymentPagesCheckoutSessionCustomFieldsLabel, :t},
      numeric: {Dhc.Stripe.PaymentPagesCheckoutSessionCustomFieldsNumeric, :t},
      optional: :boolean,
      text: {Dhc.Stripe.PaymentPagesCheckoutSessionCustomFieldsText, :t},
      type: {:enum, ["dropdown", "numeric", "text"]}
    ]
  end
end
