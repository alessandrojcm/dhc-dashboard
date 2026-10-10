defmodule Dhc.BeginnersWorkshops.IntakeEmailLog do
  @moduledoc """
  Ecto schema for `beginners_workshop_intake_emails` (ALE-380): which Intake
  Emails were queued for an Intake, and when — not delivery status.

  `occasion` names the logical sending (`"contact"` for the Batch contact
  email) and is unique per Intake, so a scheduled email is queued at most
  once however often its pass runs ("the ledger is the schedule").

  ALE-394: occasions owed once per *schedule* carry the workshop's
  reschedule number — Pre-workshop info is `pre_workshop` under the original
  schedule and `pre_workshop:<n>` after the n-th reschedule, and each
  reschedule's "Workshop rescheduled" is `rescheduled:<n>` — so a reschedule
  re-arms what the new schedule owes without touching what was sent.
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

  @doc "The Pre-workshop info occasion owed under a workshop's `reschedule_count`."
  @spec pre_workshop_occasion(non_neg_integer()) :: String.t()
  def pre_workshop_occasion(0), do: "pre_workshop"

  def pre_workshop_occasion(count) when is_integer(count) and count > 0,
    do: "pre_workshop:#{count}"

  @doc "The occasion of the `count`-th reschedule's \"Workshop rescheduled\" email."
  @spec rescheduled_occasion(pos_integer()) :: String.t()
  def rescheduled_occasion(count) when is_integer(count) and count > 0, do: "rescheduled:#{count}"

  @doc false
  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:intake_id, :email_type, :occasion, :queued_at])
    |> validate_required([:intake_id, :email_type, :occasion, :queued_at])
  end
end
