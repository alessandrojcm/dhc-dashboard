defmodule Dhc.Stripe.InvoiceRenderingPdf do
  @moduledoc """
  Provides struct and type for a InvoiceRenderingPdf
  """

  @type t :: %__MODULE__{page_size: String.t() | nil}

  defstruct [:page_size]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [page_size: {:enum, ["a4", "auto", "letter"]}]
  end
end
