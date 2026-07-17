defmodule Dhc.Stripe.CancellationDetailsParam do
  @moduledoc """
  Provides struct and types for a CancellationDetailsParam
  """

  @type t :: %__MODULE__{comment: String.t() | nil, feedback: String.t() | nil}

  defstruct [:comment, :feedback]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      comment: {:union, [:string, const: ""]},
      feedback:
        {:enum,
         [
           "",
           "customer_service",
           "low_quality",
           "missing_features",
           "other",
           "switched_service",
           "too_complex",
           "too_expensive",
           "unused"
         ]}
    ]
  end
end
