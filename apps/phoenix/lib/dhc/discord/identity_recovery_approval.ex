defmodule Dhc.Discord.IdentityRecoveryApproval do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "discord_identity_recovery_approvals" do
    field :recovery_case_id, :binary_id
    field :approver_principal_id, :binary_id
    field :approval_digest, :string
    field :source_binding_fingerprint, :string
    field :destination_principal_id, :binary_id
    field :incoming_subject_fingerprint, :string
    field :evidence_references, {:array, :string}
    field :operation, :string
    field :expires_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec, updated_at: false, inserted_at: :created_at)
  end
end
