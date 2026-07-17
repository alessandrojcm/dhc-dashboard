defmodule Dhc.Stripe.SourceRedirectFlow do
  @moduledoc """
  Provides struct and type for a SourceRedirectFlow
  """

  @type t :: %__MODULE__{
          failure_reason: String.t() | nil,
          return_url: String.t(),
          status: String.t(),
          url: String.t()
        }

  defstruct [:failure_reason, :return_url, :status, :url]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [failure_reason: :string, return_url: :string, status: :string, url: :string]
  end
end
