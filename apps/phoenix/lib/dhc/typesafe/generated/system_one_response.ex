defmodule Dhc.TypeSafe.SystemOneResponse do
  @moduledoc """
  Provides struct and type for a SystemOneResponse
  """

  @type t :: %__MODULE__{answers: map, model: String.t(), usage: Dhc.TypeSafe.Usage.t()}

  defstruct [:answers, :model, :usage]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [answers: :map, model: :string, usage: {Dhc.TypeSafe.Usage, :t}]
  end
end
