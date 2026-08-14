defmodule Dhc.Discord.IdentityRecoveryProof do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "discord_identity_recovery_proofs" do
    field :recovery_case_id, :binary_id
    field :kind, :string
    field :subject, :string
    field :subject_fingerprint, :string
    field :principal_id, :binary_id
    field :proof_digest, :string
    field :attempt, :integer
    field :expires_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec, updated_at: false, inserted_at: :created_at)
  end
end
