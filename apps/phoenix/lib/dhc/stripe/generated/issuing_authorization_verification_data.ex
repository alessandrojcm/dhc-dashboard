defmodule Dhc.Stripe.IssuingAuthorizationVerificationData do
  @moduledoc """
  Provides struct and type for a IssuingAuthorizationVerificationData
  """

  @type t :: %__MODULE__{
          address_line1_check: String.t(),
          address_postal_code_check: String.t(),
          authentication_exemption:
            Dhc.Stripe.IssuingAuthorizationAuthenticationExemption.t() | nil,
          cvc_check: String.t(),
          expiry_check: String.t(),
          postal_code: String.t() | nil,
          three_d_secure: Dhc.Stripe.IssuingAuthorizationThreeDSecure.t() | nil
        }

  defstruct [
    :address_line1_check,
    :address_postal_code_check,
    :authentication_exemption,
    :cvc_check,
    :expiry_check,
    :postal_code,
    :three_d_secure
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      address_line1_check: {:enum, ["match", "mismatch", "not_provided"]},
      address_postal_code_check: {:enum, ["match", "mismatch", "not_provided"]},
      authentication_exemption: {Dhc.Stripe.IssuingAuthorizationAuthenticationExemption, :t},
      cvc_check: {:enum, ["match", "mismatch", "not_provided"]},
      expiry_check: {:enum, ["match", "mismatch", "not_provided"]},
      postal_code: :string,
      three_d_secure: {Dhc.Stripe.IssuingAuthorizationThreeDSecure, :t}
    ]
  end
end
