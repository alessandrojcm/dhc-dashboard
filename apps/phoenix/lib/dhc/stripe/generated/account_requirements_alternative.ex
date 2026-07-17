defmodule Dhc.Stripe.AccountRequirementsAlternative do
  @moduledoc """
  Provides struct and type for a AccountRequirementsAlternative
  """

  @type t :: %__MODULE__{alternative_fields_due: [String.t()], original_fields_due: [String.t()]}

  defstruct [:alternative_fields_due, :original_fields_due]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [alternative_fields_due: [:string], original_fields_due: [:string]]
  end
end
