defmodule Dhc.Stripe.SourceTypeAlipay do
  @moduledoc """
  Provides struct and type for a SourceTypeAlipay
  """

  @type t :: %__MODULE__{
          data_string: String.t() | nil,
          native_url: String.t() | nil,
          statement_descriptor: String.t() | nil
        }

  defstruct [:data_string, :native_url, :statement_descriptor]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [data_string: :string, native_url: :string, statement_descriptor: :string]
  end
end
