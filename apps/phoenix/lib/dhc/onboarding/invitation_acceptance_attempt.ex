defmodule Dhc.Onboarding.InvitationAcceptanceAttempt do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "invitation_acceptance_attempts" do
    field :invitation_id, :binary_id
    field :status, :string, default: "processing"
    field :acceptance_data, :map
    field :stripe_customer_id, :string
    field :stripe_state, :map, default: %{}
    field :last_error, :string
    field :concluded_at, :utc_datetime

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end
end
