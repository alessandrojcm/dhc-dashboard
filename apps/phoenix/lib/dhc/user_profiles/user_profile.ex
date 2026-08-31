defmodule Dhc.UserProfiles.UserProfile do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}
  schema "user_profiles" do
    field :principal_id, Ecto.UUID
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
    # Optimistic-concurrency version witness (ADR 0023); bumped on every
    # update via `Ecto.Changeset.optimistic_lock/3`, never client-writable.
    field :lock_version, :integer, default: 1

    timestamps(inserted_at: :created_at, type: :utc_datetime)
  end

  @doc false
  def waitlist_intake_changeset(profile, attrs) do
    profile
    |> cast(attrs, [
      :first_name,
      :last_name,
      :is_active,
      :medical_conditions,
      :date_of_birth,
      :gender,
      :pronouns,
      :phone_number,
      :social_media_consent,
      :waitlist_id
    ])
    |> validate_required([
      :first_name,
      :last_name,
      :is_active,
      :date_of_birth,
      :gender,
      :phone_number,
      :social_media_consent,
      :waitlist_id
    ])
    |> validate_inclusion(:gender, [
      "man (cis)",
      "woman (cis)",
      "non-binary",
      "man (trans)",
      "woman (trans)",
      "other"
    ])
    |> validate_inclusion(:social_media_consent, [
      "no",
      "yes_recognizable",
      "yes_unrecognizable"
    ])
  end

  @doc false
  def member_profile_changeset(profile, attrs) do
    profile
    |> cast(attrs, [
      :first_name,
      :last_name,
      :medical_conditions,
      :date_of_birth,
      :gender,
      :pronouns,
      :phone_number,
      :social_media_consent
    ])
    |> validate_required([:first_name, :last_name], message: "can't be blank")
    |> validate_length(:first_name, min: 1)
    |> validate_length(:last_name, min: 1)
    |> validate_inclusion(:social_media_consent, [
      "no",
      "yes_recognizable",
      "yes_unrecognizable"
    ])
  end
end
