defmodule Dhc.Stripe.PaymentMethodDetailsMultibanco do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsMultibanco
  """

  @type t :: %__MODULE__{entity: String.t() | nil, reference: String.t() | nil}

  defstruct [:entity, :reference]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [entity: :string, reference: :string]
  end
end
