defmodule Dhc.Stripe.RefundDestinationDetailsSwish do
  @moduledoc """
  Provides struct and type for a RefundDestinationDetailsSwish
  """

  @type t :: %__MODULE__{
          network_decline_code: String.t() | nil,
          reference: String.t() | nil,
          reference_status: String.t() | nil
        }

  defstruct [:network_decline_code, :reference, :reference_status]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [network_decline_code: :string, reference: :string, reference_status: :string]
  end
end
