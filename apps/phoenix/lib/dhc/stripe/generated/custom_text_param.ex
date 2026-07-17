defmodule Dhc.Stripe.CustomTextParam do
  @moduledoc """
  Provides struct and type for a CustomTextParam
  """

  @type t :: %__MODULE__{
          after_submit: Dhc.Stripe.CustomTextPositionParam.t() | String.t() | nil,
          shipping_address: Dhc.Stripe.CustomTextPositionParam.t() | String.t() | nil,
          submit: Dhc.Stripe.CustomTextPositionParam.t() | String.t() | nil,
          terms_of_service_acceptance: Dhc.Stripe.CustomTextPositionParam.t() | String.t() | nil
        }

  defstruct [:after_submit, :shipping_address, :submit, :terms_of_service_acceptance]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      after_submit: {:union, [{Dhc.Stripe.CustomTextPositionParam, :t}, const: ""]},
      shipping_address: {:union, [{Dhc.Stripe.CustomTextPositionParam, :t}, const: ""]},
      submit: {:union, [{Dhc.Stripe.CustomTextPositionParam, :t}, const: ""]},
      terms_of_service_acceptance: {:union, [{Dhc.Stripe.CustomTextPositionParam, :t}, const: ""]}
    ]
  end
end
