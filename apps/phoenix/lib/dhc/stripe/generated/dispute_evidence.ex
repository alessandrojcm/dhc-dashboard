defmodule Dhc.Stripe.DisputeEvidence do
  @moduledoc """
  Provides struct and type for a DisputeEvidence
  """

  @type t :: %__MODULE__{
          access_activity_log: String.t() | nil,
          billing_address: String.t() | nil,
          cancellation_policy: Dhc.Stripe.File.t() | String.t() | nil,
          cancellation_policy_disclosure: String.t() | nil,
          cancellation_rebuttal: String.t() | nil,
          customer_communication: Dhc.Stripe.File.t() | String.t() | nil,
          customer_email_address: String.t() | nil,
          customer_name: String.t() | nil,
          customer_purchase_ip: String.t() | nil,
          customer_signature: Dhc.Stripe.File.t() | String.t() | nil,
          duplicate_charge_documentation: Dhc.Stripe.File.t() | String.t() | nil,
          duplicate_charge_explanation: String.t() | nil,
          duplicate_charge_id: String.t() | nil,
          enhanced_evidence: Dhc.Stripe.DisputeEnhancedEvidence.t(),
          product_description: String.t() | nil,
          receipt: Dhc.Stripe.File.t() | String.t() | nil,
          refund_policy: Dhc.Stripe.File.t() | String.t() | nil,
          refund_policy_disclosure: String.t() | nil,
          refund_refusal_explanation: String.t() | nil,
          service_date: String.t() | nil,
          service_documentation: Dhc.Stripe.File.t() | String.t() | nil,
          shipping_address: String.t() | nil,
          shipping_carrier: String.t() | nil,
          shipping_date: String.t() | nil,
          shipping_documentation: Dhc.Stripe.File.t() | String.t() | nil,
          shipping_tracking_number: String.t() | nil,
          uncategorized_file: Dhc.Stripe.File.t() | String.t() | nil,
          uncategorized_text: String.t() | nil
        }

  defstruct [
    :access_activity_log,
    :billing_address,
    :cancellation_policy,
    :cancellation_policy_disclosure,
    :cancellation_rebuttal,
    :customer_communication,
    :customer_email_address,
    :customer_name,
    :customer_purchase_ip,
    :customer_signature,
    :duplicate_charge_documentation,
    :duplicate_charge_explanation,
    :duplicate_charge_id,
    :enhanced_evidence,
    :product_description,
    :receipt,
    :refund_policy,
    :refund_policy_disclosure,
    :refund_refusal_explanation,
    :service_date,
    :service_documentation,
    :shipping_address,
    :shipping_carrier,
    :shipping_date,
    :shipping_documentation,
    :shipping_tracking_number,
    :uncategorized_file,
    :uncategorized_text
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      access_activity_log: :string,
      billing_address: :string,
      cancellation_policy: {:union, [:string, {Dhc.Stripe.File, :t}]},
      cancellation_policy_disclosure: :string,
      cancellation_rebuttal: :string,
      customer_communication: {:union, [:string, {Dhc.Stripe.File, :t}]},
      customer_email_address: :string,
      customer_name: :string,
      customer_purchase_ip: :string,
      customer_signature: {:union, [:string, {Dhc.Stripe.File, :t}]},
      duplicate_charge_documentation: {:union, [:string, {Dhc.Stripe.File, :t}]},
      duplicate_charge_explanation: :string,
      duplicate_charge_id: :string,
      enhanced_evidence: {Dhc.Stripe.DisputeEnhancedEvidence, :t},
      product_description: :string,
      receipt: {:union, [:string, {Dhc.Stripe.File, :t}]},
      refund_policy: {:union, [:string, {Dhc.Stripe.File, :t}]},
      refund_policy_disclosure: :string,
      refund_refusal_explanation: :string,
      service_date: :string,
      service_documentation: {:union, [:string, {Dhc.Stripe.File, :t}]},
      shipping_address: :string,
      shipping_carrier: :string,
      shipping_date: :string,
      shipping_documentation: {:union, [:string, {Dhc.Stripe.File, :t}]},
      shipping_tracking_number: :string,
      uncategorized_file: {:union, [:string, {Dhc.Stripe.File, :t}]},
      uncategorized_text: :string
    ]
  end
end
