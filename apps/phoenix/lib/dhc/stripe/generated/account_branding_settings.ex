defmodule Dhc.Stripe.AccountBrandingSettings do
  @moduledoc """
  Provides struct and type for a AccountBrandingSettings
  """

  @type t :: %__MODULE__{
          icon: Dhc.Stripe.File.t() | String.t() | nil,
          logo: Dhc.Stripe.File.t() | String.t() | nil,
          primary_color: String.t() | nil,
          secondary_color: String.t() | nil
        }

  defstruct [:icon, :logo, :primary_color, :secondary_color]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      icon: {:union, [:string, {Dhc.Stripe.File, :t}]},
      logo: {:union, [:string, {Dhc.Stripe.File, :t}]},
      primary_color: :string,
      secondary_color: :string
    ]
  end
end
