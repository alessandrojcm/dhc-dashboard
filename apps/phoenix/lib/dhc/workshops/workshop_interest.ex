defmodule Dhc.Workshops.WorkshopInterest do
  @moduledoc """
  Read-only Ecto schema for the `club_activity_interest` table.

  Maps the **persistence** vocabulary for member interest in planned Workshops.
  `user_id` references `auth.users(id)` — the Supabase auth user id of the
  member who expressed interest. The public/domain name exposed by
  `Dhc.Workshops` is "interest"; keep this schema internal.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "club_activity_interest" do
    field :club_activity_id, :binary_id
    field :user_id, :binary_id

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end
end
