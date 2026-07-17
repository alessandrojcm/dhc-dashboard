defmodule Dhc.Stripe.RadarReviewResourceSession do
  @moduledoc """
  Provides struct and type for a RadarReviewResourceSession
  """

  @type t :: %__MODULE__{
          browser: String.t() | nil,
          device: String.t() | nil,
          platform: String.t() | nil,
          version: String.t() | nil
        }

  defstruct [:browser, :device, :platform, :version]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [browser: :string, device: :string, platform: :string, version: :string]
  end
end
