defmodule Dhc.Stripe.AccountCardPaymentsSettings do
  @moduledoc """
  Provides struct and type for a AccountCardPaymentsSettings
  """

  @type t :: %__MODULE__{
          decline_on: Dhc.Stripe.AccountDeclineChargeOn.t() | nil,
          statement_descriptor_prefix: String.t() | nil,
          statement_descriptor_prefix_kana: String.t() | nil,
          statement_descriptor_prefix_kanji: String.t() | nil
        }

  defstruct [
    :decline_on,
    :statement_descriptor_prefix,
    :statement_descriptor_prefix_kana,
    :statement_descriptor_prefix_kanji
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      decline_on: {Dhc.Stripe.AccountDeclineChargeOn, :t},
      statement_descriptor_prefix: :string,
      statement_descriptor_prefix_kana: :string,
      statement_descriptor_prefix_kanji: :string
    ]
  end
end
