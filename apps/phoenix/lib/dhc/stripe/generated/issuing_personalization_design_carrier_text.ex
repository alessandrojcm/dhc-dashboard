defmodule Dhc.Stripe.IssuingPersonalizationDesignCarrierText do
  @moduledoc """
  Provides struct and type for a IssuingPersonalizationDesignCarrierText
  """

  @type t :: %__MODULE__{
          footer_body: String.t() | nil,
          footer_title: String.t() | nil,
          header_body: String.t() | nil,
          header_title: String.t() | nil
        }

  defstruct [:footer_body, :footer_title, :header_body, :header_title]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [footer_body: :string, footer_title: :string, header_body: :string, header_title: :string]
  end
end
