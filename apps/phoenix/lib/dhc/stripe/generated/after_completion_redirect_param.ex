defmodule Dhc.Stripe.AfterCompletionRedirectParam do
  @moduledoc """
  Provides struct and type for a AfterCompletionRedirectParam
  """

  @type t :: %__MODULE__{return_url: String.t()}

  defstruct [:return_url]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [return_url: :string]
  end
end
