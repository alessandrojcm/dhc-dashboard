defmodule Dhc.TypeSafe.ModelMetadataList do
  @moduledoc """
  Provides struct and type for a ModelMetadataList
  """

  @type t :: %__MODULE__{models: [Dhc.TypeSafe.ModelMetadata.t()]}

  defstruct [:models]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [models: [{Dhc.TypeSafe.ModelMetadata, :t}]]
  end
end
