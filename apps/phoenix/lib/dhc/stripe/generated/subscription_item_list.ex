defmodule Dhc.Stripe.SubscriptionItemList do
  @moduledoc """
  Provides struct and type for a SubscriptionItemList
  """

  @type t :: %__MODULE__{
          data: [Dhc.Stripe.SubscriptionItem.t()],
          has_more: boolean,
          object: String.t(),
          url: String.t()
        }

  defstruct [:data, :has_more, :object, :url]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      data: [{Dhc.Stripe.SubscriptionItem, :t}],
      has_more: :boolean,
      object: {:const, "list"},
      url: :string
    ]
  end
end
