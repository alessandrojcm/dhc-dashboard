defmodule Dhc.Stripe.IssuingNetworkTokenMastercard do
  @moduledoc """
  Provides struct and type for a IssuingNetworkTokenMastercard
  """

  @type t :: %__MODULE__{
          card_reference_id: String.t() | nil,
          token_reference_id: String.t(),
          token_requestor_id: String.t(),
          token_requestor_name: String.t() | nil
        }

  defstruct [:card_reference_id, :token_reference_id, :token_requestor_id, :token_requestor_name]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      card_reference_id: :string,
      token_reference_id: :string,
      token_requestor_id: :string,
      token_requestor_name: :string
    ]
  end
end
