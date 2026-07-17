defmodule Dhc.Stripe.InvoiceSettings do
  @moduledoc """
  Provides struct and type for a InvoiceSettings
  """

  @type t :: %__MODULE__{
          account_tax_ids: String.t() | [String.t()] | nil,
          days_until_due: integer | nil,
          issuer: Dhc.Stripe.Param.t() | nil
        }

  defstruct [:account_tax_ids, :days_until_due, :issuer]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      account_tax_ids: {:union, [{:const, ""}, [:string]]},
      days_until_due: :integer,
      issuer: {Dhc.Stripe.Param, :t}
    ]
  end
end
