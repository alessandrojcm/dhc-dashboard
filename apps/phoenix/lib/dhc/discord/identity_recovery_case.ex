defmodule Dhc.Discord.IdentityRecoveryCase do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "discord_identity_recovery_cases" do
    field :external_identity_id, :binary_id
    field :case_reference, :string
    field :state, :string, default: "open"
    field :reason_code, :string
    field :reporter_reference, :string
    field :binding_fingerprint, :string
    field :evidence_references, {:array, :string}, default: []
    field :actor_principal_id, :binary_id
    field :opened_at, :utc_datetime_usec
    field :destination_principal_id, :binary_id
    field :incoming_subject_fingerprint, :string
    field :operation, :string
    field :completed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false, inserted_at: :created_at)
  end

  def open_changeset(recovery_case, attrs) do
    recovery_case
    |> cast(attrs, [
      :external_identity_id,
      :case_reference,
      :state,
      :reason_code,
      :reporter_reference,
      :binding_fingerprint,
      :evidence_references,
      :actor_principal_id,
      :opened_at
    ])
    |> validate_required([
      :external_identity_id,
      :case_reference,
      :state,
      :reason_code,
      :reporter_reference,
      :binding_fingerprint,
      :evidence_references,
      :actor_principal_id,
      :opened_at
    ])
    |> validate_inclusion(:state, ["open"])
    |> validate_inclusion(:reason_code, ["promoted_binding", "replacement_request"])
    |> validate_length(:reporter_reference, min: 1, max: 128)
    |> validate_length(:evidence_references, min: 1, max: 10)
    |> unique_constraint(:external_identity_id,
      name: :discord_identity_recovery_cases_open_identity_unique
    )
    |> foreign_key_constraint(:external_identity_id)
    |> foreign_key_constraint(:actor_principal_id)
  end
end
