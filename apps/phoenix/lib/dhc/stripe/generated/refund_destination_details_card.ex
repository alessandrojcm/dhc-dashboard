defmodule Dhc.Stripe.RefundDestinationDetailsCard do
  @moduledoc """
  Provides struct and type for a RefundDestinationDetailsCard
  """

  @type t :: %__MODULE__{
          reference: String.t() | nil,
          reference_status: String.t() | nil,
          reference_type: String.t() | nil,
          type: String.t()
        }

  defstruct [:reference, :reference_status, :reference_type, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      reference: :string,
      reference_status: :string,
      reference_type: :string,
      type: {:enum, ["pending", "refund", "reversal"]}
    ]
  end
end
