defmodule Dhc.Discord.StagedAssignmentAuditEvent do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "staged_discord_assignment_audit_events" do
    field :assignment_id, :binary_id
    field :action, :string
    field :old_state, :string
    field :new_state, :string
    field :actor_principal_id, :binary_id
    field :capture_id, :binary_id
    field :stage_execution_id, :binary_id
    field :review_execution_id, :binary_id
    field :reason_code, :string
    field :tool_revision, :string
    field :subject_fingerprint, :string
    field :created_at, :utc_datetime_usec
  end
end
