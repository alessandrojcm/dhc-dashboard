defmodule Dhc.Discord.RosterReceipt do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "discord_roster_receipts" do
    field :kind, Ecto.Enum, values: [:preflight, :capture]
    field :status, Ecto.Enum, values: [:succeeded, :failed]
    belongs_to :execution, Dhc.Discord.RosterExecution
    belongs_to :actor, Dhc.Auth.Principal
    field :guild_id, :string
    field :bot_application_id, :string
    field :observed_bot_application_id, :string
    field :tool_revision, :string
    field :evidence_digest, :string
    field :package_digest, :string
    field :record_count, :integer
    field :result, :string
    belongs_to :preflight_receipt, __MODULE__, type: :binary_id

    timestamps(type: :utc_datetime_usec, updated_at: false, inserted_at: :created_at)
  end

  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [
      :kind,
      :status,
      :guild_id,
      :bot_application_id,
      :observed_bot_application_id,
      :tool_revision,
      :evidence_digest,
      :package_digest,
      :record_count,
      :result
    ])
    |> validate_required([
      :kind,
      :status,
      :execution_id,
      :actor_id,
      :guild_id,
      :bot_application_id,
      :tool_revision,
      :evidence_digest,
      :result
    ])
    |> validate_length(:result, max: 240)
    |> validate_number(:record_count, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:execution_id)
    |> foreign_key_constraint(:actor_id)
    |> foreign_key_constraint(:preflight_receipt_id)
  end
end
