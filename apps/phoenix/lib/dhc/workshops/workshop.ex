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

  import Ecto.Changeset

  alias Dhc.Destinations

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "club_activities" do
    field :title, :string
    field :description, :string
    field :location, :string
    # ALE-440: optional, manually entered destination text. The short venue
    # label (`location`) stays required and independent; it is nullable so
    # legacy rows and label-only submissions remain valid.
    field :destination_text, :string
    # ALE-442: the provider identity of a destination selected from Google
    # Maps venue search: its Place ID only, never Google's text
    # (`Dhc.Destinations` owns the rules). All absent for a manual
    # destination; a selected place carries no `destination_text`.
    field :destination_provider, :string
    field :destination_place_id, :string
    field :destination_selected_at, :utc_datetime
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
    # ALE-181: soft-delete marker. `nil` = active; a timestamp = archived.
    # `summary_query/0` filters `archived_at IS NULL` so archived Workshops
    # drop out of summaries without losing their financial/audit rows.
    field :archived_at, :utc_datetime

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end

  @management_fields ~w(title description location destination_text
    destination_place_id start_date end_date max_capacity price_member price_non_member is_public refund_days announce_discord announce_email)a
  @required_management_fields ~w(title location start_date end_date max_capacity price_member price_non_member is_public refund_days announce_discord announce_email)a

  @doc false
  def management_changeset(workshop, attrs) do
    workshop
    |> cast(attrs, @management_fields)
    # ALE-440: an emptied destination field means "absent"; the label itself
    # stays required exactly as before. The rule is shared with Beginners'
    # Workshops through `Dhc.Destinations`.
    |> Destinations.validate_changeset()
    |> validate_required(@required_management_fields)
    |> validate_length(:title, min: 1, max: 255)
    |> validate_number(:max_capacity, greater_than: 0)
    |> validate_number(:price_member, greater_than_or_equal_to: 0)
    |> validate_number(:price_non_member, greater_than_or_equal_to: 0)
    |> validate_number(:refund_days, greater_than_or_equal_to: 0)
    |> validate_end_after_start()
  end

  @doc """
  A destination-only change (ALE-443 reviewed enrichment): casts only the
  destination fields, so no label, schedule, status or pricing value can
  ride along.
  """
  @spec destination_changeset(t(), map()) :: Ecto.Changeset.t()
  def destination_changeset(%__MODULE__{} = workshop, attrs) do
    workshop
    |> cast(attrs, Destinations.fields())
    |> Destinations.validate_changeset()
  end

  defp validate_end_after_start(changeset) do
    start_date = get_field(changeset, :start_date)
    end_date = get_field(changeset, :end_date)

    if start_date && end_date && DateTime.compare(end_date, start_date) != :gt do
      add_error(changeset, :end_date, "must be after start date")
    else
      changeset
    end
  end
end
