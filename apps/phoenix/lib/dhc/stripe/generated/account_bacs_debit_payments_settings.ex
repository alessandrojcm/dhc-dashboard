defmodule Dhc.Stripe.AccountBacsDebitPaymentsSettings do
  @moduledoc """
  Provides struct and type for a AccountBacsDebitPaymentsSettings
  """

  @type t :: %__MODULE__{display_name: String.t() | nil, service_user_number: String.t() | nil}

  defstruct [:display_name, :service_user_number]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [display_name: :string, service_user_number: :string]
  end
end
