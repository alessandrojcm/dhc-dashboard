defmodule Dhc.Stripe.PortalBusinessProfile do
  @moduledoc """
  Provides struct and type for a PortalBusinessProfile
  """

  @type t :: %__MODULE__{
          headline: String.t() | nil,
          privacy_policy_url: String.t() | nil,
          terms_of_service_url: String.t() | nil
        }

  defstruct [:headline, :privacy_policy_url, :terms_of_service_url]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [headline: :string, privacy_policy_url: :string, terms_of_service_url: :string]
  end
end
