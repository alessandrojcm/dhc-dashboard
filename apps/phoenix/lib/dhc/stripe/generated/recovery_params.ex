defmodule Dhc.Stripe.RecoveryParams do
  @moduledoc """
  Provides struct and type for a RecoveryParams
  """

  @type t :: %__MODULE__{allow_promotion_codes: boolean | nil, enabled: boolean}

  defstruct [:allow_promotion_codes, :enabled]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [allow_promotion_codes: :boolean, enabled: :boolean]
  end
end
