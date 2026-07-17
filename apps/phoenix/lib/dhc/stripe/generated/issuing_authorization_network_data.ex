defmodule Dhc.Stripe.IssuingAuthorizationNetworkData do
  @moduledoc """
  Provides struct and type for a IssuingAuthorizationNetworkData
  """

  @type t :: %__MODULE__{
          acquiring_institution_id: String.t() | nil,
          system_trace_audit_number: String.t() | nil,
          transaction_id: String.t() | nil
        }

  defstruct [:acquiring_institution_id, :system_trace_audit_number, :transaction_id]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      acquiring_institution_id: :string,
      system_trace_audit_number: :string,
      transaction_id: :string
    ]
  end
end
