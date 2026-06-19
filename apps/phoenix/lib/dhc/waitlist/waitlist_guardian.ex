defmodule Dhc.Waitlist.WaitlistGuardian do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  # `waitlist_guardians` only has `created_at` (no `updated_at`); the migration
  # uses `add :created_at, :timestamptz, default: fragment("NOW()")`. Declare a
  # single timestamp field rather than `timestamps/1` (which would also emit
  # `updated_at` and fail the insert).
  schema "waitlist_guardians" do
    field :profile_id, :binary_id
    field :first_name, :string
    field :last_name, :string
    field :phone_number, :string
    field :created_at, :utc_datetime, autogenerate: {DateTime, :utc_now, []}
  end
end
