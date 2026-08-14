defmodule Dhc.Discord.IdentityRecoveryOperatorProofUse do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "discord_identity_recovery_operator_proof_uses" do
    field :proof_digest, :string
    field :manifest_digest, :string
    field :actor_principal_id, :binary_id
    field :recovery_case_id, :binary_id
    field :consumed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false, inserted_at: :created_at)
  end
end
