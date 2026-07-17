defmodule Dhc.Stripe.CustomerParam do
  @moduledoc """
  Provides struct and type for a CustomerParam
  """

  @type t :: %__MODULE__{
          custom_fields: String.t() | [map] | nil,
          default_payment_method: String.t() | nil,
          footer: String.t() | nil,
          rendering_options: Dhc.Stripe.CustomerRenderingOptionsParam.t() | String.t() | nil
        }

  defstruct [:custom_fields, :default_payment_method, :footer, :rendering_options]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      custom_fields: {:union, [{:const, ""}, [:map]]},
      default_payment_method: :string,
      footer: :string,
      rendering_options: {:union, [{Dhc.Stripe.CustomerRenderingOptionsParam, :t}, const: ""]}
    ]
  end
end
