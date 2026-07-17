defmodule Dhc.Stripe.IssuingDisputeFraudulentEvidence do
  @moduledoc """
  Provides struct and type for a IssuingDisputeFraudulentEvidence
  """

  @type t :: %__MODULE__{
          additional_documentation: Dhc.Stripe.File.t() | String.t() | nil,
          explanation: String.t() | nil
        }

  defstruct [:additional_documentation, :explanation]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [additional_documentation: {:union, [:string, {Dhc.Stripe.File, :t}]}, explanation: :string]
  end
end
