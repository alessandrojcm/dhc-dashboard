defmodule Dhc.Stripe.RefundNextAction do
  @moduledoc """
  Provides struct and type for a RefundNextAction
  """

  @type t :: %__MODULE__{
          display_details: Dhc.Stripe.RefundNextActionDisplayDetails.t() | nil,
          type: String.t()
        }

  defstruct [:display_details, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [display_details: {Dhc.Stripe.RefundNextActionDisplayDetails, :t}, type: :string]
  end
end
