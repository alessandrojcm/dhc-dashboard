defmodule Dhc.Stripe.IssuingDisputeNotReceivedEvidence do
  @moduledoc """
  Provides struct and type for a IssuingDisputeNotReceivedEvidence
  """

  @type t :: %__MODULE__{
          additional_documentation: Dhc.Stripe.File.t() | String.t() | nil,
          expected_at: integer | nil,
          explanation: String.t() | nil,
          product_description: String.t() | nil,
          product_type: String.t() | nil
        }

  defstruct [
    :additional_documentation,
    :expected_at,
    :explanation,
    :product_description,
    :product_type
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      additional_documentation: {:union, [:string, {Dhc.Stripe.File, :t}]},
      expected_at: {:integer, "unix-time"},
      explanation: :string,
      product_description: :string,
      product_type: {:enum, ["merchandise", "service"]}
    ]
  end
end
