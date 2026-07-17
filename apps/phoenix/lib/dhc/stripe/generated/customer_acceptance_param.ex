defmodule Dhc.Stripe.CustomerAcceptanceParam do
  @moduledoc """
  Provides struct and types for a CustomerAcceptanceParam
  """

  @type t :: %__MODULE__{
          accepted_at: integer | nil,
          offline: map | nil,
          online: Dhc.Stripe.OnlineParam.t() | nil,
          type: String.t()
        }

  defstruct [:accepted_at, :offline, :online, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      accepted_at: {:integer, "unix-time"},
      offline: :map,
      online: {Dhc.Stripe.OnlineParam, :t},
      type: {:enum, ["offline", "offline", "online", "online", "online"]}
    ]
  end
end
