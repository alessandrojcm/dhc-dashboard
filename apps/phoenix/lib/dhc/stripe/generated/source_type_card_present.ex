defmodule Dhc.Stripe.SourceTypeCardPresent do
  @moduledoc """
  Provides struct and type for a SourceTypeCardPresent
  """

  @type t :: %__MODULE__{
          application_cryptogram: String.t() | nil,
          application_preferred_name: String.t() | nil,
          authorization_code: String.t() | nil,
          authorization_response_code: String.t() | nil,
          brand: String.t() | nil,
          country: String.t() | nil,
          cvm_type: String.t() | nil,
          data_type: String.t() | nil,
          dedicated_file_name: String.t() | nil,
          emv_auth_data: String.t() | nil,
          evidence_customer_signature: String.t() | nil,
          evidence_transaction_certificate: String.t() | nil,
          exp_month: integer | nil,
          exp_year: integer | nil,
          fingerprint: String.t() | nil,
          funding: String.t() | nil,
          last4: String.t() | nil,
          pos_device_id: String.t() | nil,
          pos_entry_mode: String.t() | nil,
          read_method: String.t() | nil,
          reader: String.t() | nil,
          terminal_verification_results: String.t() | nil,
          transaction_status_information: String.t() | nil
        }

  defstruct [
    :application_cryptogram,
    :application_preferred_name,
    :authorization_code,
    :authorization_response_code,
    :brand,
    :country,
    :cvm_type,
    :data_type,
    :dedicated_file_name,
    :emv_auth_data,
    :evidence_customer_signature,
    :evidence_transaction_certificate,
    :exp_month,
    :exp_year,
    :fingerprint,
    :funding,
    :last4,
    :pos_device_id,
    :pos_entry_mode,
    :read_method,
    :reader,
    :terminal_verification_results,
    :transaction_status_information
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      application_cryptogram: :string,
      application_preferred_name: :string,
      authorization_code: :string,
      authorization_response_code: :string,
      brand: :string,
      country: :string,
      cvm_type: :string,
      data_type: :string,
      dedicated_file_name: :string,
      emv_auth_data: :string,
      evidence_customer_signature: :string,
      evidence_transaction_certificate: :string,
      exp_month: :integer,
      exp_year: :integer,
      fingerprint: :string,
      funding: :string,
      last4: :string,
      pos_device_id: :string,
      pos_entry_mode: :string,
      read_method: :string,
      reader: :string,
      terminal_verification_results: :string,
      transaction_status_information: :string
    ]
  end
end
