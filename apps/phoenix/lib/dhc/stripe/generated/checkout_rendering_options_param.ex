defmodule Dhc.Stripe.CheckoutRenderingOptionsParam do
  @moduledoc """
  Provides struct and type for a CheckoutRenderingOptionsParam
  """

  @type t :: %__MODULE__{amount_tax_display: String.t() | nil, template: String.t() | nil}

  defstruct [:amount_tax_display, :template]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [amount_tax_display: {:enum, ["", "exclude_tax", "include_inclusive_tax"]}, template: :string]
  end
end
