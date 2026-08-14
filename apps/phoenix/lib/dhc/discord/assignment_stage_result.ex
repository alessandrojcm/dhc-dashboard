defmodule Dhc.Discord.AssignmentStageResult do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "discord_assignment_stage_results" do
    field :stage_execution_id, :binary_id
    field :principal_id, :binary_id
    field :subject_fingerprint, :string
    field :outcome, :string
    field :assignment_id, :binary_id
    field :reason_code, :string
    timestamps(type: :utc_datetime_usec, updated_at: false, inserted_at: :created_at)
  end

  def changeset(result, attrs) do
    result
    |> cast(attrs, [
      :stage_execution_id,
      :principal_id,
      :subject_fingerprint,
      :outcome,
      :assignment_id,
      :reason_code
    ])
    |> validate_required([:stage_execution_id, :principal_id, :subject_fingerprint, :outcome])
    |> validate_inclusion(:outcome, ["proposed", "conflicted"])
    |> foreign_key_constraint(:stage_execution_id)
    |> foreign_key_constraint(:principal_id)
    |> foreign_key_constraint(:assignment_id)
    |> check_constraint(:outcome, name: :discord_assignment_stage_results_outcome_check)
  end
end
