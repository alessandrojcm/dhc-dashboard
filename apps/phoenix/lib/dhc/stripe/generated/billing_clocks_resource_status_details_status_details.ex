defmodule Dhc.Stripe.BillingClocksResourceStatusDetailsStatusDetails do
  @moduledoc """
  Provides struct and type for a BillingClocksResourceStatusDetailsStatusDetails
  """

  @type t :: %__MODULE__{
          advancing: Dhc.Stripe.BillingClocksResourceStatusDetailsAdvancingStatusDetails.t() | nil
        }

  defstruct [:advancing]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [advancing: {Dhc.Stripe.BillingClocksResourceStatusDetailsAdvancingStatusDetails, :t}]
  end
end
