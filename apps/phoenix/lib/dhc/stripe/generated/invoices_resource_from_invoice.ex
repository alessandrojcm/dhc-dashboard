defmodule Dhc.Stripe.InvoicesResourceFromInvoice do
  @moduledoc """
  Provides struct and type for a InvoicesResourceFromInvoice
  """

  @type t :: %__MODULE__{action: String.t(), invoice: Dhc.Stripe.Invoice.t() | String.t()}

  defstruct [:action, :invoice]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [action: :string, invoice: {:union, [:string, {Dhc.Stripe.Invoice, :t}]}]
  end
end
