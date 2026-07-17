defmodule Dhc.Stripe.PlatformEarningFeeSource do
  @moduledoc """
  Provides struct and type for a PlatformEarningFeeSource
  """

  @type t :: %__MODULE__{charge: String.t() | nil, payout: String.t() | nil, type: String.t()}

  defstruct [:charge, :payout, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [charge: :string, payout: :string, type: {:enum, ["charge", "payout"]}]
  end
end
