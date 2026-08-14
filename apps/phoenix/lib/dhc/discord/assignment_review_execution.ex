defmodule Dhc.Discord.AssignmentReviewExecution do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "discord_assignment_review_executions" do
    field :capture_id, :binary_id
    field :manifest_digest, :string
    field :reviewer_principal_id, :binary_id
    field :tool_revision, :string
    field :executed_at, :utc_datetime_usec
    field :state, :string
    field :reason_code, :string
    timestamps(type: :utc_datetime_usec, updated_at: false, inserted_at: :created_at)
  end

  def changeset(execution, attrs) do
    execution
    |> cast(attrs, [
      :capture_id,
      :manifest_digest,
      :reviewer_principal_id,
      :tool_revision,
      :executed_at,
      :state,
      :reason_code
    ])
    |> validate_required([
      :capture_id,
      :manifest_digest,
      :reviewer_principal_id,
      :tool_revision,
      :executed_at,
      :state
    ])
    |> validate_inclusion(:state, ["applied", "rejected"])
    |> check_constraint(:state, name: :discord_assignment_review_executions_lifecycle_check)
    |> unique_constraint([:capture_id, :manifest_digest],
      name: :discord_assignment_review_executions_manifest_unique
    )
    |> foreign_key_constraint(:capture_id)
    |> foreign_key_constraint(:reviewer_principal_id)
  end
end
