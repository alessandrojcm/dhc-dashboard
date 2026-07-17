defmodule Dhc.Stripe.PaymentMethodDetailsInteracPresentReceipt do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsInteracPresentReceipt
  """

  @type t :: %__MODULE__{
          account_type: String.t() | nil,
          application_cryptogram: String.t() | nil,
          application_preferred_name: String.t() | nil,
          authorization_code: String.t() | nil,
          authorization_response_code: String.t() | nil,
          cardholder_verification_method: String.t() | nil,
          dedicated_file_name: String.t() | nil,
          terminal_verification_results: String.t() | nil,
          transaction_status_information: String.t() | nil
        }

  defstruct [
    :account_type,
    :application_cryptogram,
    :application_preferred_name,
    :authorization_code,
    :authorization_response_code,
    :cardholder_verification_method,
    :dedicated_file_name,
    :terminal_verification_results,
    :transaction_status_information
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      account_type: {:enum, ["checking", "savings", "unknown"]},
      application_cryptogram: :string,
      application_preferred_name: :string,
      authorization_code: :string,
      authorization_response_code: :string,
      cardholder_verification_method: :string,
      dedicated_file_name: :string,
      terminal_verification_results: :string,
      transaction_status_information: :string
    ]
  end
end
