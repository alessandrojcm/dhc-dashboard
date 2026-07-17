defmodule Dhc.Stripe.IssuingDisputeMerchandiseNotAsDescribedEvidence do
  @moduledoc """
  Provides struct and type for a IssuingDisputeMerchandiseNotAsDescribedEvidence
  """

  @type t :: %__MODULE__{
          additional_documentation: Dhc.Stripe.File.t() | String.t() | nil,
          explanation: String.t() | nil,
          received_at: integer | nil,
          return_description: String.t() | nil,
          return_status: String.t() | nil,
          returned_at: integer | nil
        }

  defstruct [
    :additional_documentation,
    :explanation,
    :received_at,
    :return_description,
    :return_status,
    :returned_at
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      additional_documentation: {:union, [:string, {Dhc.Stripe.File, :t}]},
      explanation: :string,
      received_at: {:integer, "unix-time"},
      return_description: :string,
      return_status: {:enum, ["merchant_rejected", "successful"]},
      returned_at: {:integer, "unix-time"}
    ]
  end
end
