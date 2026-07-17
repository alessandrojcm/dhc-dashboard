defmodule Dhc.Stripe.TransferSchedule do
  @moduledoc """
  Provides struct and type for a TransferSchedule
  """

  @type t :: %__MODULE__{
          delay_days: integer,
          interval: String.t(),
          monthly_anchor: integer | nil,
          monthly_payout_days: [integer] | nil,
          weekly_anchor: String.t() | nil,
          weekly_payout_days: [String.t()] | nil
        }

  defstruct [
    :delay_days,
    :interval,
    :monthly_anchor,
    :monthly_payout_days,
    :weekly_anchor,
    :weekly_payout_days
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      delay_days: :integer,
      interval: :string,
      monthly_anchor: :integer,
      monthly_payout_days: [:integer],
      weekly_anchor: :string,
      weekly_payout_days: [enum: ["friday", "monday", "thursday", "tuesday", "wednesday"]]
    ]
  end
end
