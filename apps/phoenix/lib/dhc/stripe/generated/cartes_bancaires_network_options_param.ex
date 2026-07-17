defmodule Dhc.Stripe.CartesBancairesNetworkOptionsParam do
  @moduledoc """
  Provides struct and types for a CartesBancairesNetworkOptionsParam
  """

  @type t :: %__MODULE__{
          cb_avalgo: String.t(),
          cb_exemption: String.t() | nil,
          cb_score: integer | nil
        }

  defstruct [:cb_avalgo, :cb_exemption, :cb_score]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      cb_avalgo: {:enum, ["0", "1", "2", "3", "4", "A"]},
      cb_exemption: :string,
      cb_score: :integer
    ]
  end
end
