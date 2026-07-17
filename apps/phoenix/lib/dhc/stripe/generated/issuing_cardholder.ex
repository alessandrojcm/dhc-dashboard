defmodule Dhc.Stripe.IssuingCardholder do
  @moduledoc """
  Provides struct and type for a IssuingCardholder
  """

  @type t :: %__MODULE__{
          billing: Dhc.Stripe.IssuingCardholderAddress.t(),
          company: Dhc.Stripe.IssuingCardholderCompany.t() | nil,
          created: integer,
          email: String.t() | nil,
          id: String.t(),
          individual: Dhc.Stripe.IssuingCardholderIndividual.t() | nil,
          livemode: boolean,
          metadata: map,
          name: String.t(),
          object: String.t(),
          phone_number: String.t() | nil,
          preferred_locales: [String.t()] | nil,
          requirements: Dhc.Stripe.IssuingCardholderRequirements.t(),
          spending_controls: Dhc.Stripe.IssuingCardholderAuthorizationControls.t() | nil,
          status: String.t(),
          type: String.t()
        }

  defstruct [
    :billing,
    :company,
    :created,
    :email,
    :id,
    :individual,
    :livemode,
    :metadata,
    :name,
    :object,
    :phone_number,
    :preferred_locales,
    :requirements,
    :spending_controls,
    :status,
    :type
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      billing: {Dhc.Stripe.IssuingCardholderAddress, :t},
      company: {Dhc.Stripe.IssuingCardholderCompany, :t},
      created: {:integer, "unix-time"},
      email: :string,
      id: :string,
      individual: {Dhc.Stripe.IssuingCardholderIndividual, :t},
      livemode: :boolean,
      metadata: :map,
      name: :string,
      object: {:const, "issuing.cardholder"},
      phone_number: :string,
      preferred_locales: [enum: ["de", "en", "es", "fr", "it"]],
      requirements: {Dhc.Stripe.IssuingCardholderRequirements, :t},
      spending_controls: {Dhc.Stripe.IssuingCardholderAuthorizationControls, :t},
      status: {:enum, ["active", "blocked", "inactive"]},
      type: {:enum, ["company", "individual"]}
    ]
  end
end
