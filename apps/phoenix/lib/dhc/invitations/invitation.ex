defmodule Dhc.Invitations.Invitation do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @type t :: %__MODULE__{}
  schema "invitations" do
    field :email, :string
    field :user_id, Ecto.UUID
    field :waitlist_id, Ecto.UUID
    field :status, :string, default: "pending"
    field :expires_at, :utc_datetime
    field :created_by, Ecto.UUID
    field :invitation_type, :string
    field :metadata, :map

    timestamps(type: :utc_datetime)
  end
end
