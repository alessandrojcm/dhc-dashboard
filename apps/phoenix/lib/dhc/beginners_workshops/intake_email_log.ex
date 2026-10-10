defmodule Dhc.BeginnersWorkshops.IntakeEmailLog do
  @moduledoc """
  Ecto schema for `beginners_workshop_intake_emails` (ALE-380): which Intake
  Emails were queued for an Intake, and when — not delivery status.

  `occasion` names the logical sending (`"contact"` for the Batch contact
  email) and is unique per Intake, so a scheduled email is queued at most
  once however often its pass runs ("the ledger is the schedule").
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "beginners_workshop_intake_emails" do
    field :intake_id, :binary_id
    field :email_type, :string
    field :occasion, :string
    field :queued_at, :utc_datetime_usec
  end

  @doc false
  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:intake_id, :email_type, :occasion, :queued_at])
    |> validate_required([:intake_id, :email_type, :occasion, :queued_at])
  end
end
