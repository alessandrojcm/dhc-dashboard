defmodule Dhc.Stripe.BillingClocksResourceStatusDetailsAdvancingStatusDetails do
  @moduledoc """
  Provides struct and type for a BillingClocksResourceStatusDetailsAdvancingStatusDetails
  """

  @type t :: %__MODULE__{target_frozen_time: integer}

  defstruct [:target_frozen_time]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [target_frozen_time: {:integer, "unix-time"}]
  end
end
