defmodule Dhc.Onboarding.InvitationAcceptanceDiscordCollisionAuditEvent do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "invitation_acceptance_discord_collision_audit_events" do
    field :continuation_id, :binary_id
    field :existing_principal_id, :binary_id
    field :subject_fingerprint, :string
    field :reason_code, :string
    field :created_at, :utc_datetime
  end
end
