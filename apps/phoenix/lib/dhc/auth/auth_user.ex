defmodule Dhc.Auth.AuthUser do
  @moduledoc """
  Read-only Ecto schema mapping `id` and `email` from `auth.users`.

  `auth.users` is owned by Supabase Auth — this schema is never used to write
  or migrate. It exists to isolate the single `auth.users` read touchpoint
  (joining member email into the members-list query) behind an idiomatic
  Ecto struct instead of a raw `Repo.query!`.

  The table lives in the `auth` schema prefix; queries must pass
  `prefix: "auth"` (or rely on the schema's `@schema_prefix` — set here so
  the read site can do `from u in AuthUser` without remembering the prefix).
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  @schema_prefix "auth"
  schema "users" do
    field :email, :string

    # `auth.users` carries many Supabase-managed columns; we deliberately map
    # only `id` and `email` to keep this read-only surface minimal. Do not
    # add writable fields or changesets here — Supabase Auth owns writes.
  end

  # Explicitly disable writes: there is no changeset, and consumers should use
  # this struct only for reads. Supabase Auth remains the sole writer.
end
