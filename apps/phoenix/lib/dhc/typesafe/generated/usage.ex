defmodule Dhc.TypeSafe.Usage do
  @moduledoc """
  Provides struct and type for a Usage
  """

  @type t :: %__MODULE__{input_tokens: integer, output_tokens: integer}

  defstruct [:input_tokens, :output_tokens]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [input_tokens: :integer, output_tokens: :integer]
  end
end
