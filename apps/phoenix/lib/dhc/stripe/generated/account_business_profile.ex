defmodule Dhc.Stripe.AccountBusinessProfile do
  @moduledoc """
  Provides struct and type for a AccountBusinessProfile
  """

  @type t :: %__MODULE__{
          annual_revenue: Dhc.Stripe.AccountAnnualRevenue.t() | nil,
          estimated_worker_count: integer | nil,
          mcc: String.t() | nil,
          minority_owned_business_designation: [String.t()] | nil,
          monthly_estimated_revenue: Dhc.Stripe.AccountMonthlyEstimatedRevenue.t() | nil,
          name: String.t() | nil,
          product_description: String.t() | nil,
          support_address: Dhc.Stripe.Address.t() | nil,
          support_email: String.t() | nil,
          support_phone: String.t() | nil,
          support_url: String.t() | nil,
          url: String.t() | nil
        }

  defstruct [
    :annual_revenue,
    :estimated_worker_count,
    :mcc,
    :minority_owned_business_designation,
    :monthly_estimated_revenue,
    :name,
    :product_description,
    :support_address,
    :support_email,
    :support_phone,
    :support_url,
    :url
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      annual_revenue: {Dhc.Stripe.AccountAnnualRevenue, :t},
      estimated_worker_count: :integer,
      mcc: :string,
      minority_owned_business_designation: [
        enum: [
          "lgbtqi_owned_business",
          "minority_owned_business",
          "none_of_these_apply",
          "prefer_not_to_answer",
          "women_owned_business"
        ]
      ],
      monthly_estimated_revenue: {Dhc.Stripe.AccountMonthlyEstimatedRevenue, :t},
      name: :string,
      product_description: :string,
      support_address: {Dhc.Stripe.Address, :t},
      support_email: :string,
      support_phone: :string,
      support_url: :string,
      url: :string
    ]
  end
end
