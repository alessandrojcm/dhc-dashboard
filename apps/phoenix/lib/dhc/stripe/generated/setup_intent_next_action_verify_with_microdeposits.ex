defmodule Dhc.Stripe.SetupIntentNextActionVerifyWithMicrodeposits do
  @moduledoc """
  Provides struct and type for a SetupIntentNextActionVerifyWithMicrodeposits
  """

  @type t :: %__MODULE__{
          arrival_date: integer,
          hosted_verification_url: String.t(),
          microdeposit_type: String.t() | nil
        }

  defstruct [:arrival_date, :hosted_verification_url, :microdeposit_type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      arrival_date: {:integer, "unix-time"},
      hosted_verification_url: :string,
      microdeposit_type: {:enum, ["amounts", "descriptor_code"]}
    ]
  end
end
