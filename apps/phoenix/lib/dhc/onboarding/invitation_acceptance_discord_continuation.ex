defmodule Dhc.Onboarding.InvitationAcceptanceDiscordContinuation do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "invitation_acceptance_discord_continuations" do
    field :invitation_id, :binary_id
    field :attempt_id, :binary_id
    field :status, :string, default: "awaiting_oauth"
    field :expires_at, :utc_datetime
    field :concluded_at, :utc_datetime

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end
end
