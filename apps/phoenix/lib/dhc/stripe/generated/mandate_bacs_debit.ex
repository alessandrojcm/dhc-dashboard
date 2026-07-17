defmodule Dhc.Stripe.MandateBacsDebit do
  @moduledoc """
  Provides struct and type for a MandateBacsDebit
  """

  @type t :: %__MODULE__{
          display_name: String.t() | nil,
          network_status: String.t(),
          reference: String.t(),
          revocation_reason: String.t() | nil,
          service_user_number: String.t() | nil,
          url: String.t()
        }

  defstruct [
    :display_name,
    :network_status,
    :reference,
    :revocation_reason,
    :service_user_number,
    :url
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      display_name: :string,
      network_status: {:enum, ["accepted", "pending", "refused", "revoked"]},
      reference: :string,
      revocation_reason:
        {:enum,
         [
           "account_closed",
           "bank_account_restricted",
           "bank_ownership_changed",
           "could_not_process",
           "debit_not_authorized"
         ]},
      service_user_number: :string,
      url: :string
    ]
  end
end
