defmodule Dhc.Workshops.ExternalUser do
  @moduledoc """
  Read-only Ecto schema for the `external_users` table.

  Maps the **persistence** vocabulary for non-member Workshop participants
  (external registrations). The public/domain name exposed by `Dhc.Workshops`
  is the normalized "participant" DTO (`type: :external`); keep this schema
  internal so storage join details do not leak into API responses.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "external_users" do
    field :first_name, :string
    field :last_name, :string
    field :email, :string
    field :phone_number, :string

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end
end
