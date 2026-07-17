defmodule Dhc.Stripe.OnlineParam do
  @moduledoc """
  Provides struct and types for a OnlineParam
  """

  @type t :: %__MODULE__{ip_address: String.t() | nil, user_agent: String.t() | nil}

  defstruct [:ip_address, :user_agent]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [ip_address: :string, user_agent: :string]
  end
end
