defmodule Dhc.Stripe.PaymentLinksResourceCustomFields do
  @moduledoc """
  Provides struct and type for a PaymentLinksResourceCustomFields
  """

  @type t :: %__MODULE__{
          dropdown: Dhc.Stripe.PaymentLinksResourceCustomFieldsDropdown.t() | nil,
          key: String.t(),
          label: Dhc.Stripe.PaymentLinksResourceCustomFieldsLabel.t(),
          numeric: Dhc.Stripe.PaymentLinksResourceCustomFieldsNumeric.t() | nil,
          optional: boolean,
          text: Dhc.Stripe.PaymentLinksResourceCustomFieldsText.t() | nil,
          type: String.t()
        }

  defstruct [:dropdown, :key, :label, :numeric, :optional, :text, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      dropdown: {Dhc.Stripe.PaymentLinksResourceCustomFieldsDropdown, :t},
      key: :string,
      label: {Dhc.Stripe.PaymentLinksResourceCustomFieldsLabel, :t},
      numeric: {Dhc.Stripe.PaymentLinksResourceCustomFieldsNumeric, :t},
      optional: :boolean,
      text: {Dhc.Stripe.PaymentLinksResourceCustomFieldsText, :t},
      type: {:enum, ["dropdown", "numeric", "text"]}
    ]
  end
end
