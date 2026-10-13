defmodule Dhc.TypeSafe.ModelMetadata do
  @moduledoc """
  Provides struct and type for a ModelMetadata
  """

  @type t :: %__MODULE__{description: String.t(), name: String.t(), release_date: String.t()}

  defstruct [:description, :name, :release_date]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [description: :string, name: :string, release_date: :string]
  end
end
