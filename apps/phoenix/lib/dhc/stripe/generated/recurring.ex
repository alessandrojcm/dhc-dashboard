defmodule Dhc.Stripe.Recurring do
  @moduledoc """
  Provides struct and types for a Recurring
  """

  @type t :: %__MODULE__{
          interval: String.t(),
          interval_count: integer | nil,
          meter: String.t() | nil,
          usage_type: String.t() | nil
        }

  defstruct [:interval, :interval_count, :meter, :usage_type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      interval: {:enum, ["day", "month", "week", "year"]},
      interval_count: :integer,
      meter: :string,
      usage_type: {:enum, ["licensed", "metered"]}
    ]
  end
end
