defmodule Dhc.Workshops.Refund do
  @moduledoc """
  Read-only Ecto schema for the `club_activity_refunds` table.

  Maps the **persistence** vocabulary for Workshop refunds. Each refund is tied
  to a single registration (`registration_id` → `club_activity_registrations`),
  and the participant identity is reached through that registration. The
  public/domain name exposed by `Dhc.Workshops` is "refund"; keep this schema
  internal.

  `status` is the Postgres `refund_status` enum (`pending`, `processing`,
  `completed`, `failed`, `cancelled`), declared as `:string` (Postgres
  implicitly casts enum ↔ text). `requested_by` / `processed_by` reference
  `auth.users(id)` (nullable).
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "club_activity_refunds" do
    field :registration_id, :binary_id

    field :refund_amount, :integer
    field :refund_reason, :string
    field :status, :string, default: "pending"

    field :stripe_refund_id, :string
    field :stripe_payment_intent_id, :string

    field :requested_at, :utc_datetime
    field :processed_at, :utc_datetime
    field :completed_at, :utc_datetime

    # `requested_by` / `processed_by` reference `auth.users(id)` (nullable).
    field :requested_by, :binary_id
    field :processed_by, :binary_id

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end
end
