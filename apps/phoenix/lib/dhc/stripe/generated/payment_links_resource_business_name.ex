defmodule Dhc.Stripe.PaymentLinksResourceBusinessName do
  @moduledoc """
  Provides struct and type for a PaymentLinksResourceBusinessName
  """

  @type t :: %__MODULE__{enabled: boolean, optional: boolean}

  defstruct [:enabled, :optional]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [enabled: :boolean, optional: :boolean]
  end
end
