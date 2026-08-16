defmodule Dhc.Onboarding.InvitationAcceptanceDiscordSubjectClaim do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "invitation_acceptance_discord_subject_claims" do
    field :continuation_id, :binary_id
    field :provider, :string
    field :provider_subject, :string

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end
end
