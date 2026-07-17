defmodule Dhc.Stripe.AccountTreasurySettings do
  @moduledoc """
  Provides struct and type for a AccountTreasurySettings
  """

  @type t :: %__MODULE__{tos_acceptance: Dhc.Stripe.AccountTermsOfService.t() | nil}

  defstruct [:tos_acceptance]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [tos_acceptance: {Dhc.Stripe.AccountTermsOfService, :t}]
  end
end
