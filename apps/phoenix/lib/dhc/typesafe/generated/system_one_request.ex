defmodule Dhc.TypeSafe.SystemOneRequest do
  @moduledoc """
  Provides struct and type for a SystemOneRequest
  """

  @type t :: %__MODULE__{model: String.t(), questions: map, state: map | String.t() | [map]}

  defstruct [:model, :questions, :state]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [model: :string, questions: :map, state: {:union, [:map, :string, [:map]]}]
  end
end
