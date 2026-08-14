defmodule Dhc.Discord.IdentityBindingHistory do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "discord_identity_binding_history" do
    field :recovery_case_id, :binary_id
    field :old_external_identity_id, :binary_id
    field :new_external_identity_id, :binary_id
    field :source_principal_id, :binary_id
    field :destination_principal_id, :binary_id
    field :operation, :string
    field :incoming_subject_fingerprint, :string
    timestamps(type: :utc_datetime_usec, updated_at: false, inserted_at: :created_at)
  end
end
