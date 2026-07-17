defmodule Dhc.Stripe.IssuingAuthorizationFleetCardholderPromptData do
  @moduledoc """
  Provides struct and type for a IssuingAuthorizationFleetCardholderPromptData
  """

  @type t :: %__MODULE__{
          alphanumeric_id: String.t() | nil,
          driver_id: String.t() | nil,
          odometer: integer | nil,
          unspecified_id: String.t() | nil,
          user_id: String.t() | nil,
          vehicle_number: String.t() | nil
        }

  defstruct [:alphanumeric_id, :driver_id, :odometer, :unspecified_id, :user_id, :vehicle_number]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      alphanumeric_id: :string,
      driver_id: :string,
      odometer: :integer,
      unspecified_id: :string,
      user_id: :string,
      vehicle_number: :string
    ]
  end
end
