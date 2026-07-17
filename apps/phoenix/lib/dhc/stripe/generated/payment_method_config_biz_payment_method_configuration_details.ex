defmodule Dhc.Stripe.PaymentMethodConfigBizPaymentMethodConfigurationDetails do
  @moduledoc """
  Provides struct and type for a PaymentMethodConfigBizPaymentMethodConfigurationDetails
  """

  @type t :: %__MODULE__{id: String.t(), parent: String.t() | nil}

  defstruct [:id, :parent]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [id: :string, parent: :string]
  end
end
