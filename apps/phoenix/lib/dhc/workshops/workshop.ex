defmodule Dhc.Workshops.Workshop do
  @moduledoc """
  Read-only Ecto schema for the `club_activities` table.

  Maps the **persistence** vocabulary for Workshops. `club_activities` /
  `club_activity*` are storage names only; the public/domain names exposed by
  `Dhc.Workshops` read-model helpers use Workshop language (Workshop, interest,
  registration, attendee, refund). Keep this schema internal — do not return
  it directly from a controller; build a domain-shaped DTO in the context
  instead.

  The table is created by the baseline Ecto migration
  `20260512000007_create_club_activities` and owned by the application. Its
  `status` column is the Postgres `club_activity_status` enum, declared here as
  `:string` (Postgres implicitly casts enum ↔ text at the column boundary, so
  no custom Ecto type is needed — same pattern as `WaitlistEntry.status`).
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "club_activities" do
    field :title, :string
    field :description, :string
    field :location, :string
    field :start_date, :utc_datetime
    field :end_date, :utc_datetime
    field :max_capacity, :integer
    field :price_member, :float
    field :price_non_member, :float
    field :is_public, :boolean, default: false
    field :refund_days, :integer, default: 3
    field :status, :string, default: "planned"
    field :announce_discord, :boolean, default: false
    field :announce_email, :boolean, default: false
    # `created_by` references `auth.users(id)` (Supabase-owned); read-only here.
    field :created_by, :binary_id

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end
end
