defmodule Dhc.Workshops.Registration do
  @moduledoc """
  Read-only Ecto schema for the `club_activity_registrations` table.

  Maps the **persistence** vocabulary for Workshop registrations (attendees).
  A registration is either a member registration (`member_user_id` set,
  referencing `user_profiles.supabase_user_id`) or an external registration
  (`external_user_id` set, referencing `external_users(id)`); a CHECK
  constraint enforces exactly-one. The public/domain name exposed by
  `Dhc.Workshops` is "attendee"/"registration"; keep this schema internal.

  `status` is the Postgres `registration_status` enum (`pending`, `confirmed`,
  `cancelled`, `refunded`), declared as `:string` (Postgres implicitly casts
  enum ↔ text). `attendance_status` is a plain `text` column constrained by a
  CHECK to `pending`/`attended`/`no_show`/`excused`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "club_activity_registrations" do
    field :club_activity_id, :binary_id
    # `member_user_id` references `user_profiles.supabase_user_id` (nullable).
    field :member_user_id, :binary_id
    field :external_user_id, :binary_id

    field :stripe_checkout_session_id, :string
    field :amount_paid, :integer
    field :currency, :string, default: "eur"
    field :status, :string, default: "pending"
    field :registered_at, :utc_datetime
    field :confirmed_at, :utc_datetime
    field :cancelled_at, :utc_datetime
    field :registration_notes, :string

    field :attendance_status, :string, default: "pending"
    field :attendance_marked_at, :utc_datetime
    # `attendance_marked_by` references `auth.users(id)` (nullable).
    field :attendance_marked_by, :binary_id
    field :attendance_notes, :string

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end
end
