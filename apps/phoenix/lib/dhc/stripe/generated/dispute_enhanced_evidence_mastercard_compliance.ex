defmodule Dhc.Stripe.DisputeEnhancedEvidenceMastercardCompliance do
  @moduledoc """
  Provides struct and type for a DisputeEnhancedEvidenceMastercardCompliance
  """

  @type t :: %__MODULE__{fee_acknowledged: boolean}

  defstruct [:fee_acknowledged]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [fee_acknowledged: :boolean]
  end
end
