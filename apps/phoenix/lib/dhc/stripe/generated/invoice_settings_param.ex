defmodule Dhc.Stripe.InvoiceSettingsParam do
  @moduledoc """
  Provides struct and type for a InvoiceSettingsParam
  """

  @type t :: %__MODULE__{
          account_tax_ids: String.t() | [String.t()] | nil,
          custom_fields: String.t() | [map] | nil,
          description: String.t() | nil,
          footer: String.t() | nil,
          issuer: Dhc.Stripe.Param.t() | nil
        }

  defstruct [:account_tax_ids, :custom_fields, :description, :footer, :issuer]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      account_tax_ids: {:union, [{:const, ""}, [:string]]},
      custom_fields: {:union, [{:const, ""}, [:map]]},
      description: :string,
      footer: :string,
      issuer: {Dhc.Stripe.Param, :t}
    ]
  end
end
