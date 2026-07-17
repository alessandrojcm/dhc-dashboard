defmodule Dhc.Stripe.ChargeFraudDetails do
  @moduledoc """
  Provides struct and type for a ChargeFraudDetails
  """

  @type t :: %__MODULE__{stripe_report: String.t() | nil, user_report: String.t() | nil}

  defstruct [:stripe_report, :user_report]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [stripe_report: :string, user_report: :string]
  end
end
