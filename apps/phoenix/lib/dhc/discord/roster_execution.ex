defmodule Dhc.Discord.RosterExecution do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "discord_roster_executions" do
    belongs_to :actor, Dhc.Auth.Principal
    field :guild_id, :string
    field :bot_application_id, :string
    field :tool_revision, :string
    field :status, Ecto.Enum, values: [:approved, :running, :succeeded, :failed]
    field :approved_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  def approval_changeset(execution, attrs) do
    execution
    |> cast(attrs, [
      :guild_id,
      :bot_application_id,
      :tool_revision,
      :status,
      :approved_at,
      :expires_at
    ])
    |> validate_required([
      :actor_id,
      :guild_id,
      :bot_application_id,
      :tool_revision,
      :status,
      :approved_at,
      :expires_at
    ])
    |> validate_inclusion(:status, [:approved])
    |> foreign_key_constraint(:actor_id)
  end

  def transition_changeset(execution, attrs) do
    execution
    |> cast(attrs, [:status, :started_at, :finished_at])
    |> validate_required([:status])
  end
end
