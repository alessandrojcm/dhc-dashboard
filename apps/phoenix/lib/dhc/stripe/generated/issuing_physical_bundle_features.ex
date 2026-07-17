defmodule Dhc.Stripe.IssuingPhysicalBundleFeatures do
  @moduledoc """
  Provides struct and type for a IssuingPhysicalBundleFeatures
  """

  @type t :: %__MODULE__{card_logo: String.t(), carrier_text: String.t(), second_line: String.t()}

  defstruct [:card_logo, :carrier_text, :second_line]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      card_logo: {:enum, ["optional", "required", "unsupported"]},
      carrier_text: {:enum, ["optional", "required", "unsupported"]},
      second_line: {:enum, ["optional", "required", "unsupported"]}
    ]
  end
end
