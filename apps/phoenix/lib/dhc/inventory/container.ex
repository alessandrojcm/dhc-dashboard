defmodule Dhc.Inventory.Container do
  @moduledoc """
  Read-only Ecto schema for the `containers` table.

  Maps the **persistence** vocabulary for Inventory storage locations.
  `containers` is a storage name only; the public/domain name exposed by
  `Dhc.Inventory` read-model helpers uses Inventory language (Container).
  Keep this schema internal — do not return it directly from a controller;
  build a domain-shaped DTO in the context instead.

  The table is created by the baseline Ecto migration
  `20260512000010_create_inventory` and owned by the application.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "containers" do
    field :name, :string
    field :description, :string
    field :parent_container_id, :binary_id
    # `created_by` references `auth.users(id)` (Supabase-owned); read-only here.
    field :created_by, :binary_id

    # `timestamps(inserted_at: :created_at)` — the production `containers`
    # table uses `created_at`/`updated_at`, not `inserted_at`/`updated_at`.
    # The baseline migration mirrors this with
    # `timestamps(type: :timestamptz, inserted_at: :created_at)`. The Ecto
    # schema side uses `:utc_datetime` (the Elixir type that maps to Postgres
    # `timestamptz`). See AGENTS.md `created_at` vs `inserted_at` divergence
    # note and the Workshops baseline fix for the same pattern.
    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end
end