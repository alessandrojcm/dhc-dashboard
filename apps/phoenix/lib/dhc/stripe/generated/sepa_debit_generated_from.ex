defmodule Dhc.Stripe.SepaDebitGeneratedFrom do
  @moduledoc """
  Provides struct and type for a SepaDebitGeneratedFrom
  """

  @type t :: %__MODULE__{
          charge: Dhc.Stripe.Charge.t() | String.t() | nil,
          setup_attempt: Dhc.Stripe.SetupAttempt.t() | String.t() | nil
        }

  defstruct [:charge, :setup_attempt]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      charge: {:union, [:string, {Dhc.Stripe.Charge, :t}]},
      setup_attempt: {:union, [:string, {Dhc.Stripe.SetupAttempt, :t}]}
    ]
  end
end
