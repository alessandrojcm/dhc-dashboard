defmodule Dhc.Stripe.InvoiceMandateOptionsPayto do
  @moduledoc """
  Provides struct and type for a InvoiceMandateOptionsPayto
  """

  @type t :: %__MODULE__{
          amount: integer | nil,
          amount_type: String.t() | nil,
          purpose: String.t() | nil
        }

  defstruct [:amount, :amount_type, :purpose]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      amount_type: {:enum, ["fixed", "maximum"]},
      purpose:
        {:enum,
         [
           "dependant_support",
           "government",
           "loan",
           "mortgage",
           "other",
           "pension",
           "personal",
           "retail",
           "salary",
           "tax",
           "utility"
         ]}
    ]
  end
end
