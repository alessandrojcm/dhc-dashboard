defmodule Dhc.Discord.StagedAssignment do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "staged_discord_assignments" do
    field :principal_id, :binary_id
    field :capture_id, :binary_id
    field :stage_execution_id, :binary_id
    field :provider, :string, default: "discord"
    field :provider_subject, :string
    field :username_snapshot, :string
    field :subject_fingerprint, :string
    field :proposal_digest, :string
    field :state, :string, default: "proposed"
    field :prepared_by_principal_id, :binary_id
    field :approved_by_principal_id, :binary_id
    field :review_execution_id, :binary_id
    field :approved_at, :utc_datetime_usec
    field :terminal_at, :utc_datetime_usec
    field :terminal_actor_principal_id, :binary_id
    field :reason_code, :string
    field :superseded_by_id, :binary_id
    field :tool_revision, :string

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  def proposal_changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [
      :principal_id,
      :capture_id,
      :stage_execution_id,
      :provider,
      :provider_subject,
      :username_snapshot,
      :subject_fingerprint,
      :proposal_digest,
      :state,
      :prepared_by_principal_id,
      :tool_revision
    ])
    |> validate_required([
      :principal_id,
      :capture_id,
      :stage_execution_id,
      :provider,
      :provider_subject,
      :username_snapshot,
      :subject_fingerprint,
      :proposal_digest,
      :state,
      :prepared_by_principal_id,
      :tool_revision
    ])
    |> validate_inclusion(:provider, ["discord"])
    |> validate_inclusion(:state, ["proposed"])
    |> unique_constraint(:principal_id, name: :staged_discord_assignments_active_principal)
    |> unique_constraint([:provider, :provider_subject],
      name: :staged_discord_assignments_active_subject
    )
    |> unique_constraint(:proposal_digest,
      name: :staged_discord_assignments_proposal_digest_unique
    )
    |> foreign_key_constraint(:principal_id)
    |> foreign_key_constraint(:capture_id)
    |> foreign_key_constraint(:stage_execution_id)
    |> check_constraint(:principal_id, name: :staged_discord_assignments_member_link)
    |> check_constraint(:provider_subject,
      name: :staged_discord_assignments_external_identity_conflict
    )
    |> check_constraint(:provider_subject,
      name: :staged_discord_assignments_subject_claim_conflict
    )
  end

  def transition_changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [
      :state,
      :approved_by_principal_id,
      :review_execution_id,
      :approved_at,
      :terminal_at,
      :terminal_actor_principal_id,
      :reason_code,
      :superseded_by_id
    ])
    |> validate_required([:state])
    |> foreign_key_constraint(:approved_by_principal_id)
    |> foreign_key_constraint(:review_execution_id)
    |> foreign_key_constraint(:terminal_actor_principal_id)
    |> foreign_key_constraint(:superseded_by_id)
    |> check_constraint(:state, name: :staged_discord_assignments_lifecycle_check)
    |> check_constraint(:state, name: :staged_discord_assignments_transition_check)
    |> check_constraint(:provider_subject,
      name: :staged_discord_assignments_external_identity_conflict
    )
    |> check_constraint(:provider_subject,
      name: :staged_discord_assignments_subject_claim_conflict
    )
  end
end
