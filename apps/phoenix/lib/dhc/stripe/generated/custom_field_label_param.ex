defmodule Dhc.Stripe.CustomFieldLabelParam do
  @moduledoc """
  Provides struct and type for a CustomFieldLabelParam
  """

  @type t :: %__MODULE__{custom: String.t(), type: String.t()}

  defstruct [:custom, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [custom: :string, type: {:const, "custom"}]
  end
end
