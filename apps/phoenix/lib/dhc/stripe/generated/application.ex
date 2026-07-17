defmodule Dhc.Stripe.Application do
  @moduledoc """
  Provides struct and type for a Application
  """

  @type t :: %__MODULE__{id: String.t(), name: String.t() | nil, object: String.t()}

  defstruct [:id, :name, :object]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [id: :string, name: :string, object: {:const, "application"}]
  end
end
