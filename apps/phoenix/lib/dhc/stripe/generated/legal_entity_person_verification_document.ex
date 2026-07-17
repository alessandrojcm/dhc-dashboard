defmodule Dhc.Stripe.LegalEntityPersonVerificationDocument do
  @moduledoc """
  Provides struct and type for a LegalEntityPersonVerificationDocument
  """

  @type t :: %__MODULE__{
          back: Dhc.Stripe.File.t() | String.t() | nil,
          details: String.t() | nil,
          details_code: String.t() | nil,
          front: Dhc.Stripe.File.t() | String.t() | nil
        }

  defstruct [:back, :details, :details_code, :front]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      back: {:union, [:string, {Dhc.Stripe.File, :t}]},
      details: :string,
      details_code: :string,
      front: {:union, [:string, {Dhc.Stripe.File, :t}]}
    ]
  end
end
