defmodule Dhc.Stripe.SourceTypeWechat do
  @moduledoc """
  Provides struct and type for a SourceTypeWechat
  """

  @type t :: %__MODULE__{
          prepay_id: String.t() | nil,
          qr_code_url: String.t() | nil,
          statement_descriptor: String.t() | nil
        }

  defstruct [:prepay_id, :qr_code_url, :statement_descriptor]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [prepay_id: :string, qr_code_url: :string, statement_descriptor: :string]
  end
end
