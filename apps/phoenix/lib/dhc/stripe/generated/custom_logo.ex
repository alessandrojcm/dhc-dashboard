defmodule Dhc.Stripe.CustomLogo do
  @moduledoc """
  Provides struct and type for a CustomLogo
  """

  @type t :: %__MODULE__{content_type: String.t() | nil, url: String.t()}

  defstruct [:content_type, :url]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [content_type: :string, url: :string]
  end
end
