defmodule Dhc.Stripe.AccountTosAcceptance do
  @moduledoc """
  Provides struct and type for a AccountTosAcceptance
  """

  @type t :: %__MODULE__{
          date: integer | nil,
          ip: String.t() | nil,
          service_agreement: String.t() | nil,
          user_agent: String.t() | nil
        }

  defstruct [:date, :ip, :service_agreement, :user_agent]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [date: {:integer, "unix-time"}, ip: :string, service_agreement: :string, user_agent: :string]
  end
end
