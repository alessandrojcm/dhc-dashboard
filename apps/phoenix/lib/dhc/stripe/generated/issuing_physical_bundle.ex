defmodule Dhc.Stripe.IssuingPhysicalBundle do
  @moduledoc """
  Provides struct and type for a IssuingPhysicalBundle
  """

  @type t :: %__MODULE__{
          features: Dhc.Stripe.IssuingPhysicalBundleFeatures.t(),
          id: String.t(),
          livemode: boolean,
          name: String.t(),
          object: String.t(),
          status: String.t(),
          type: String.t()
        }

  defstruct [:features, :id, :livemode, :name, :object, :status, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      features: {Dhc.Stripe.IssuingPhysicalBundleFeatures, :t},
      id: :string,
      livemode: :boolean,
      name: :string,
      object: {:const, "issuing.physical_bundle"},
      status: {:enum, ["active", "inactive", "review"]},
      type: {:enum, ["custom", "standard"]}
    ]
  end
end
