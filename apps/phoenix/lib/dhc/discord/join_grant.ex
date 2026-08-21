defmodule Dhc.Discord.JoinGrant do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "discord_join_grants" do
    field :continuation_id, :binary_id
    field :attempt_id, :binary_id
    field :encrypted_access_token, :string
    field :expires_at, :utc_datetime

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end
end
