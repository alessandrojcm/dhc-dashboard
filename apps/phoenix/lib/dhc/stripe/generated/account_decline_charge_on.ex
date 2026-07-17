defmodule Dhc.Stripe.AccountDeclineChargeOn do
  @moduledoc """
  Provides struct and type for a AccountDeclineChargeOn
  """

  @type t :: %__MODULE__{avs_failure: boolean, cvc_failure: boolean}

  defstruct [:avs_failure, :cvc_failure]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [avs_failure: :boolean, cvc_failure: :boolean]
  end
end
