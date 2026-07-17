defmodule Dhc.Stripe.SetupIntentDataParam do
  @moduledoc """
  Provides struct and type for a SetupIntentDataParam
  """

  @type t :: %__MODULE__{
          description: String.t() | nil,
          metadata: map | nil,
          on_behalf_of: String.t() | nil
        }

  defstruct [:description, :metadata, :on_behalf_of]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [description: :string, metadata: :map, on_behalf_of: :string]
  end
end
