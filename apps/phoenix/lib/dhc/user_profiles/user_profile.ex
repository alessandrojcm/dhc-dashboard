defmodule Dhc.UserProfiles.UserProfile do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}
  schema "user_profiles" do
    field :supabase_user_id, Ecto.UUID
    field :first_name, :string
    field :last_name, :string
    field :is_active, :boolean, default: true
    field :medical_conditions, :string
    field :date_of_birth, :date
    field :gender, :string
    field :pronouns, :string
    field :phone_number, :string
    field :social_media_consent, :string
    field :customer_id, :string
    field :waitlist_id, Ecto.UUID

    timestamps(type: :utc_datetime)
  end
end
