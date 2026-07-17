defmodule Dhc.Stripe.MandateOptionsParam do
  @moduledoc """
  Provides struct and types for a MandateOptionsParam
  """

  @type t :: %__MODULE__{
          amount: integer | nil,
          amount_type: String.t() | nil,
          collection_method: String.t() | nil,
          custom_mandate_url: String.t() | nil,
          default_for: [String.t()] | nil,
          description: String.t() | nil,
          end_date: integer | nil,
          interval: String.t(),
          interval_count: integer | nil,
          interval_description: String.t() | nil,
          payment_schedule: String.t() | nil,
          purpose: String.t() | nil,
          reference: String.t(),
          start_date: integer,
          supported_types: [String.t()] | nil,
          transaction_type: String.t() | nil
        }

  defstruct [
    :amount,
    :amount_type,
    :collection_method,
    :custom_mandate_url,
    :default_for,
    :description,
    :end_date,
    :interval,
    :interval_count,
    :interval_description,
    :payment_schedule,
    :purpose,
    :reference,
    :start_date,
    :supported_types,
    :transaction_type
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      amount_type: {:enum, ["fixed", "maximum"]},
      collection_method: {:enum, ["", "paper"]},
      custom_mandate_url: {:union, [:string, const: ""]},
      default_for: [enum: ["invoice", "subscription"]],
      description: :string,
      end_date: {:integer, "unix-time"},
      interval: {:enum, ["day", "month", "sporadic", "week", "year"]},
      interval_count: :integer,
      interval_description: :string,
      payment_schedule: {:enum, ["combined", "interval", "sporadic"]},
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
         ]},
      reference: :string,
      start_date: {:integer, "unix-time"},
      supported_types: [const: "india"],
      transaction_type: {:enum, ["business", "personal"]}
    ]
  end
end
