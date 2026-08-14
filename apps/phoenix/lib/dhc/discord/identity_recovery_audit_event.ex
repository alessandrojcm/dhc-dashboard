defmodule Dhc.Discord.IdentityRecoveryAuditEvent do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "discord_identity_recovery_audit_events" do
    field :recovery_case_id, :binary_id
    field :action, :string
    field :actor_principal_id, :binary_id

    timestamps(type: :utc_datetime_usec, updated_at: false, inserted_at: :created_at)
  end

  def open_changeset(event, attrs) do
    event
    |> cast(attrs, [:recovery_case_id, :action, :actor_principal_id])
    |> validate_required([:recovery_case_id, :action, :actor_principal_id])
    |> validate_inclusion(:action, ["opened_and_contained"])
    |> foreign_key_constraint(:recovery_case_id)
    |> foreign_key_constraint(:actor_principal_id)
  end
end
