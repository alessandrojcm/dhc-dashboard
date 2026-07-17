defmodule Dhc.Stripe.AccountDashboardSettings do
  @moduledoc """
  Provides struct and type for a AccountDashboardSettings
  """

  @type t :: %__MODULE__{display_name: String.t() | nil, timezone: String.t() | nil}

  defstruct [:display_name, :timezone]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [display_name: :string, timezone: :string]
  end
end
