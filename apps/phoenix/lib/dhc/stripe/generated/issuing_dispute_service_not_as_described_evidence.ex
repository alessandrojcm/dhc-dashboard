defmodule Dhc.Stripe.IssuingDisputeServiceNotAsDescribedEvidence do
  @moduledoc """
  Provides struct and type for a IssuingDisputeServiceNotAsDescribedEvidence
  """

  @type t :: %__MODULE__{
          additional_documentation: Dhc.Stripe.File.t() | String.t() | nil,
          canceled_at: integer | nil,
          cancellation_reason: String.t() | nil,
          explanation: String.t() | nil,
          received_at: integer | nil
        }

  defstruct [
    :additional_documentation,
    :canceled_at,
    :cancellation_reason,
    :explanation,
    :received_at
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      additional_documentation: {:union, [:string, {Dhc.Stripe.File, :t}]},
      canceled_at: {:integer, "unix-time"},
      cancellation_reason: :string,
      explanation: :string,
      received_at: {:integer, "unix-time"}
    ]
  end
end
