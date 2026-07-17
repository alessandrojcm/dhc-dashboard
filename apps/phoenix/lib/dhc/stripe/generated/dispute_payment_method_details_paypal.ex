defmodule Dhc.Stripe.DisputePaymentMethodDetailsPaypal do
  @moduledoc """
  Provides struct and type for a DisputePaymentMethodDetailsPaypal
  """

  @type t :: %__MODULE__{case_id: String.t() | nil, reason_code: String.t() | nil}

  defstruct [:case_id, :reason_code]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [case_id: :string, reason_code: :string]
  end
end
