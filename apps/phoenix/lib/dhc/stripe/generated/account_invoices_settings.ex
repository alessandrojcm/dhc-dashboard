defmodule Dhc.Stripe.AccountInvoicesSettings do
  @moduledoc """
  Provides struct and type for a AccountInvoicesSettings
  """

  @type t :: %__MODULE__{
          default_account_tax_ids: [Dhc.Stripe.TaxId.t() | String.t()] | nil,
          hosted_payment_method_save: String.t() | nil
        }

  defstruct [:default_account_tax_ids, :hosted_payment_method_save]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      default_account_tax_ids: [union: [:string, {Dhc.Stripe.TaxId, :t}]],
      hosted_payment_method_save: {:enum, ["always", "never", "offer"]}
    ]
  end
end
