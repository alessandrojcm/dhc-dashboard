defmodule Dhc.Stripe.CustomFieldDropdownParam do
  @moduledoc """
  Provides struct and type for a CustomFieldDropdownParam
  """

  @type t :: %__MODULE__{
          default_value: String.t() | nil,
          options: [Dhc.Stripe.CustomFieldOptionParam.t()]
        }

  defstruct [:default_value, :options]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [default_value: :string, options: [{Dhc.Stripe.CustomFieldOptionParam, :t}]]
  end
end
