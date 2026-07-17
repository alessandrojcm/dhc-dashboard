defmodule Dhc.Stripe.IssuingNetworkTokenVisa do
  @moduledoc """
  Provides struct and type for a IssuingNetworkTokenVisa
  """

  @type t :: %__MODULE__{
          card_reference_id: String.t() | nil,
          token_reference_id: String.t(),
          token_requestor_id: String.t(),
          token_risk_score: String.t() | nil
        }

  defstruct [:card_reference_id, :token_reference_id, :token_requestor_id, :token_risk_score]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      card_reference_id: :string,
      token_reference_id: :string,
      token_requestor_id: :string,
      token_risk_score: :string
    ]
  end
end
