defmodule Dhc.Stripe.AutomaticTax do
  @moduledoc """
  Provides struct and type for a AutomaticTax
  """

  @type t :: %__MODULE__{
          disabled_reason: String.t() | nil,
          enabled: boolean,
          liability: Dhc.Stripe.ConnectAccountReference.t() | nil,
          provider: String.t() | nil,
          status: String.t() | nil
        }

  defstruct [:disabled_reason, :enabled, :liability, :provider, :status]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      disabled_reason:
        {:enum, ["finalization_requires_location_inputs", "finalization_system_error"]},
      enabled: :boolean,
      liability: {Dhc.Stripe.ConnectAccountReference, :t},
      provider: :string,
      status: {:enum, ["complete", "failed", "requires_location_inputs"]}
    ]
  end
end
