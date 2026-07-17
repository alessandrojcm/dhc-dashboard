defmodule Dhc.Stripe.PaymentMethodPaypal do
  @moduledoc """
  Provides struct and type for a PaymentMethodPaypal
  """

  @type t :: %__MODULE__{
          country: String.t() | nil,
          payer_email: String.t() | nil,
          payer_id: String.t() | nil
        }

  defstruct [:country, :payer_email, :payer_id]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [country: :string, payer_email: :string, payer_id: :string]
  end
end
