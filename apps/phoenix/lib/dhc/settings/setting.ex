defmodule Dhc.Settings.Setting do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @type t :: %__MODULE__{}
  schema "settings" do
    field :key, :string
    field :value, :string
    field :type, :string
    field :description, :string
    field :updated_by, :binary_id
    # Production Supabase uses `created_at` (see the original
    # `20241213134629_create_settings_table.sql`). The Ecto baseline migration
    # mirrors this via `timestamps(inserted_at: :created_at)`.
    field :created_at, :utc_datetime
    field :updated_at, :utc_datetime
  end
end
