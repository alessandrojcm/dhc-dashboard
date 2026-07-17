defmodule Dhc.Stripe.FileLink do
  @moduledoc """
  Provides struct and type for a FileLink
  """

  @type t :: %__MODULE__{
          created: integer,
          expired: boolean,
          expires_at: integer | nil,
          file: Dhc.Stripe.File.t() | String.t(),
          id: String.t(),
          livemode: boolean,
          metadata: map,
          object: String.t(),
          url: String.t() | nil
        }

  defstruct [:created, :expired, :expires_at, :file, :id, :livemode, :metadata, :object, :url]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      created: {:integer, "unix-time"},
      expired: :boolean,
      expires_at: {:integer, "unix-time"},
      file: {:union, [:string, {Dhc.Stripe.File, :t}]},
      id: :string,
      livemode: :boolean,
      metadata: :map,
      object: {:const, "file_link"},
      url: :string
    ]
  end
end
