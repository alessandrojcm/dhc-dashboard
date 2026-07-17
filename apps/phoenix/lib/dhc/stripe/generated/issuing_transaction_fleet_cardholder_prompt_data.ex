defmodule Dhc.Stripe.IssuingTransactionFleetCardholderPromptData do
  @moduledoc """
  Provides struct and type for a IssuingTransactionFleetCardholderPromptData
  """

  @type t :: %__MODULE__{
          driver_id: String.t() | nil,
          odometer: integer | nil,
          unspecified_id: String.t() | nil,
          user_id: String.t() | nil,
          vehicle_number: String.t() | nil
        }

  defstruct [:driver_id, :odometer, :unspecified_id, :user_id, :vehicle_number]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      driver_id: :string,
      odometer: :integer,
      unspecified_id: :string,
      user_id: :string,
      vehicle_number: :string
    ]
  end
end
