defmodule Dhc.Stripe.ProductData do
  @moduledoc """
  Provides struct and type for a ProductData
  """

  @type t :: %__MODULE__{
          description: String.t() | nil,
          images: [String.t()] | nil,
          metadata: map | nil,
          name: String.t(),
          tax_code: String.t() | nil,
          unit_label: String.t() | nil
        }

  defstruct [:description, :images, :metadata, :name, :tax_code, :unit_label]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      description: :string,
      images: [:string],
      metadata: :map,
      name: :string,
      tax_code: :string,
      unit_label: :string
    ]
  end
end
