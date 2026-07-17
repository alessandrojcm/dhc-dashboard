defmodule Dhc.Stripe.LegalEntityUboDeclaration do
  @moduledoc """
  Provides struct and type for a LegalEntityUboDeclaration
  """

  @type t :: %__MODULE__{date: integer | nil, ip: String.t() | nil, user_agent: String.t() | nil}

  defstruct [:date, :ip, :user_agent]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [date: {:integer, "unix-time"}, ip: :string, user_agent: :string]
  end
end
