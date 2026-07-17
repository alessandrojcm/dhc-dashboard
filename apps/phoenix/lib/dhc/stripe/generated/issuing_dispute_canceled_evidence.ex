defmodule Dhc.Stripe.IssuingDisputeCanceledEvidence do
  @moduledoc """
  Provides struct and type for a IssuingDisputeCanceledEvidence
  """

  @type t :: %__MODULE__{
          additional_documentation: Dhc.Stripe.File.t() | String.t() | nil,
          canceled_at: integer | nil,
          cancellation_policy_provided: boolean | nil,
          cancellation_reason: String.t() | nil,
          expected_at: integer | nil,
          explanation: String.t() | nil,
          product_description: String.t() | nil,
          product_type: String.t() | nil,
          return_status: String.t() | nil,
          returned_at: integer | nil
        }

  defstruct [
    :additional_documentation,
    :canceled_at,
    :cancellation_policy_provided,
    :cancellation_reason,
    :expected_at,
    :explanation,
    :product_description,
    :product_type,
    :return_status,
    :returned_at
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      additional_documentation: {:union, [:string, {Dhc.Stripe.File, :t}]},
      canceled_at: {:integer, "unix-time"},
      cancellation_policy_provided: :boolean,
      cancellation_reason: :string,
      expected_at: {:integer, "unix-time"},
      explanation: :string,
      product_description: :string,
      product_type: {:enum, ["merchandise", "service"]},
      return_status: {:enum, ["merchant_rejected", "successful"]},
      returned_at: {:integer, "unix-time"}
    ]
  end
end
