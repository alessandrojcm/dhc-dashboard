defmodule Dhc.Stripe.PaymentLinksResourceCustomFieldsDropdown do
  @moduledoc """
  Provides struct and type for a PaymentLinksResourceCustomFieldsDropdown
  """

  @type t :: %__MODULE__{
          default_value: String.t() | nil,
          options: [Dhc.Stripe.PaymentLinksResourceCustomFieldsDropdownOption.t()]
        }

  defstruct [:default_value, :options]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      default_value: :string,
      options: [{Dhc.Stripe.PaymentLinksResourceCustomFieldsDropdownOption, :t}]
    ]
  end
end
