defmodule Dhc.Stripe.IssuingPersonalizationDesignPreferences do
  @moduledoc """
  Provides struct and type for a IssuingPersonalizationDesignPreferences
  """

  @type t :: %__MODULE__{is_default: boolean, is_platform_default: boolean | nil}

  defstruct [:is_default, :is_platform_default]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [is_default: :boolean, is_platform_default: :boolean]
  end
end
