defmodule Dhc.Stripe.NetworkOptionsParam do
  @moduledoc """
  Provides struct and types for a NetworkOptionsParam
  """

  @type t :: %__MODULE__{
          cartes_bancaires: Dhc.Stripe.CartesBancairesNetworkOptionsParam.t() | nil
        }

  defstruct [:cartes_bancaires]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [cartes_bancaires: {Dhc.Stripe.CartesBancairesNetworkOptionsParam, :t}]
  end
end
