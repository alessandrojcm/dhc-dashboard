defmodule Dhc.Stripe.SubscriptionsResourcePauseCollection do
  @moduledoc """
  Provides struct and type for a SubscriptionsResourcePauseCollection
  """

  @type t :: %__MODULE__{behavior: String.t(), resumes_at: integer | nil}

  defstruct [:behavior, :resumes_at]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      behavior: {:enum, ["keep_as_draft", "mark_uncollectible", "void"]},
      resumes_at: {:integer, "unix-time"}
    ]
  end
end
