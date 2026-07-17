defmodule Dhc.Stripe.IssuingDisputeDuplicateEvidence do
  @moduledoc """
  Provides struct and type for a IssuingDisputeDuplicateEvidence
  """

  @type t :: %__MODULE__{
          additional_documentation: Dhc.Stripe.File.t() | String.t() | nil,
          card_statement: Dhc.Stripe.File.t() | String.t() | nil,
          cash_receipt: Dhc.Stripe.File.t() | String.t() | nil,
          check_image: Dhc.Stripe.File.t() | String.t() | nil,
          explanation: String.t() | nil,
          original_transaction: String.t() | nil
        }

  defstruct [
    :additional_documentation,
    :card_statement,
    :cash_receipt,
    :check_image,
    :explanation,
    :original_transaction
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      additional_documentation: {:union, [:string, {Dhc.Stripe.File, :t}]},
      card_statement: {:union, [:string, {Dhc.Stripe.File, :t}]},
      cash_receipt: {:union, [:string, {Dhc.Stripe.File, :t}]},
      check_image: {:union, [:string, {Dhc.Stripe.File, :t}]},
      explanation: :string,
      original_transaction: :string
    ]
  end
end
