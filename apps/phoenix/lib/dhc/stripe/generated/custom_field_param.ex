defmodule Dhc.Stripe.CustomFieldParam do
  @moduledoc """
  Provides struct and type for a CustomFieldParam
  """

  @type t :: %__MODULE__{
          dropdown: Dhc.Stripe.CustomFieldDropdownParam.t() | nil,
          key: String.t(),
          label: Dhc.Stripe.CustomFieldLabelParam.t(),
          numeric: Dhc.Stripe.CustomFieldNumericParam.t() | nil,
          optional: boolean | nil,
          text: Dhc.Stripe.CustomFieldTextParam.t() | nil,
          type: String.t()
        }

  defstruct [:dropdown, :key, :label, :numeric, :optional, :text, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      dropdown: {Dhc.Stripe.CustomFieldDropdownParam, :t},
      key: :string,
      label: {Dhc.Stripe.CustomFieldLabelParam, :t},
      numeric: {Dhc.Stripe.CustomFieldNumericParam, :t},
      optional: :boolean,
      text: {Dhc.Stripe.CustomFieldTextParam, :t},
      type: {:enum, ["dropdown", "numeric", "text"]}
    ]
  end
end
