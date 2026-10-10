defmodule Dhc.BeginnersWorkshops.IntakeEvent do
  @moduledoc """
  Ecto schema for `beginners_workshop_intake_events` (ALE-386): an Intake's
  history. One row per console Intake command that did something — which
  command, which Principal ran it, when, and the optional note the
  coordinator gave, and (ALE-393) for an attendance correction the state it
  corrected the Intake to — plus (ALE-395) the workshop's cancellation and
  (ALE-390, story 97) every door `check_in` and `undo_check_in`, so the
  attendance record keeps who did what and when after an undo or an
  unassignment. A repeated command that found nothing to do writes no
  row. Rows are only ever inserted, by the boundary, in the command's own
  transaction.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @note_max 500

  schema "beginners_workshop_intake_events" do
    field :intake_id, :binary_id
    field :command, :string
    field :actor_principal_id, :binary_id
    field :note, :string
    # ALE-393: the state a `correct_attendance` row corrected the Intake to.
    field :correction, :string
    field :occurred_at, :utc_datetime_usec
  end

  @doc "The longest note a command accepts."
  @spec note_max() :: pos_integer()
  def note_max, do: @note_max

  @doc false
  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :id,
      :intake_id,
      :command,
      :actor_principal_id,
      :note,
      :correction,
      :occurred_at
    ])
    |> validate_required([:intake_id, :command, :occurred_at])
    |> validate_length(:note, max: @note_max)
  end
end
