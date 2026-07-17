defmodule Dhc.Stripe.TestHelpersTestClock do
  @moduledoc """
  Provides struct and type for a TestHelpersTestClock
  """

  @type t :: %__MODULE__{
          created: integer,
          deletes_after: integer,
          frozen_time: integer,
          id: String.t(),
          livemode: boolean,
          name: String.t() | nil,
          object: String.t(),
          status: String.t(),
          status_details: Dhc.Stripe.BillingClocksResourceStatusDetailsStatusDetails.t()
        }

  defstruct [
    :created,
    :deletes_after,
    :frozen_time,
    :id,
    :livemode,
    :name,
    :object,
    :status,
    :status_details
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      created: {:integer, "unix-time"},
      deletes_after: {:integer, "unix-time"},
      frozen_time: {:integer, "unix-time"},
      id: :string,
      livemode: :boolean,
      name: :string,
      object: {:const, "test_helpers.test_clock"},
      status: {:enum, ["advancing", "internal_failure", "ready"]},
      status_details: {Dhc.Stripe.BillingClocksResourceStatusDetailsStatusDetails, :t}
    ]
  end
end
