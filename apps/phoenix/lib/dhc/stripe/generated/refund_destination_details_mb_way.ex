defmodule Dhc.Stripe.RefundDestinationDetailsMbWay do
  @moduledoc """
  Provides struct and type for a RefundDestinationDetailsMbWay
  """

  @type t :: %__MODULE__{reference: String.t() | nil, reference_status: String.t() | nil}

  defstruct [:reference, :reference_status]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [reference: :string, reference_status: :string]
  end
end
