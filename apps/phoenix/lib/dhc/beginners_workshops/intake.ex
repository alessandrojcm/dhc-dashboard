defmodule Dhc.BeginnersWorkshops.Intake do
  @moduledoc """
  Ecto schema for `beginners_workshop_intakes` (ALE-380, CONTEXT.md
  "Intake"): one person's place in one Beginners' Workshop.

  It references the Waitlist person (`waitlist_id`, nulled on anonymisation)
  and stores no copy of them. `origin` is `batch` (with `batch_id`) or
  `fast_track`; `queue_date` is the person's priority date when drafted.
  `contacted` and `paid` are open states; a person has at most one open
  Intake (partial unique index). `state` changes only through the boundary's
  transition table.

  The capability link token is rebuilt from the Intake id and
  `link_generation` (`Dhc.BeginnersWorkshops.IntakeLink`); only its hash is
  stored.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @states ~w(contacted paid attended no_show lapsed declined returned deferred cancelled_refunded withdrawn)
  @open_states ~w(contacted paid)
  @origins ~w(batch fast_track)
  @paid_via ~w(stripe carried_fee)

  schema "beginners_workshop_intakes" do
    field :workshop_id, :binary_id
    field :waitlist_id, :binary_id
    field :state, :string, default: "contacted"
    field :origin, :string
    field :batch_id, :binary_id
    field :queue_date, :utc_datetime
    field :link_generation, :integer, default: 1
    field :link_token_hash, :binary, redact: true
    field :contacted_at, :utc_datetime_usec
    # How a `paid` Intake was paid (ALE-381: `stripe`; `carried_fee` arrives
    # with the Carried Fee) and when.
    field :paid_via, :string
    field :paid_at, :utc_datetime_usec
    # Door check-in (ALE-390): who checked the person in and when. Names a
    # Principal, so it outlives that person's Staff assignment.
    field :checked_in_at, :utc_datetime_usec
    field :checked_in_by_principal_id, :binary_id

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @doc "Every Intake state."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "The open states: a person has at most one Intake in them."
  @spec open_states() :: [String.t()]
  def open_states, do: @open_states

  @doc "Every origin."
  @spec origins() :: [String.t()]
  def origins, do: @origins

  @doc """
  A new `contacted` Intake. `attrs` carry the id (the link token is derived
  from it before insert), workshop, person, origin, batch, queue date, link
  hash and contact time.
  """
  @spec contact_changeset(map()) :: Ecto.Changeset.t()
  def contact_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :id,
      :workshop_id,
      :waitlist_id,
      :origin,
      :batch_id,
      :queue_date,
      :link_token_hash,
      :contacted_at
    ])
    |> put_change(:state, "contacted")
    |> put_change(:link_generation, 1)
    |> validate_required([
      :id,
      :workshop_id,
      :waitlist_id,
      :origin,
      :queue_date,
      :link_token_hash,
      :contacted_at
    ])
    |> validate_inclusion(:origin, @origins)
  end

  @doc "A `contacted` Intake becoming `paid` (`paid_via` is how)."
  @spec paid_changeset(t(), String.t(), DateTime.t()) :: Ecto.Changeset.t()
  def paid_changeset(%__MODULE__{} = intake, paid_via, at) do
    intake
    |> change(state: "paid", paid_via: paid_via, paid_at: at)
    |> validate_inclusion(:paid_via, @paid_via)
  end

  @doc "A `paid` Intake checked in at the door by `principal_id` at `at`."
  @spec check_in_changeset(t(), binary(), DateTime.t()) :: Ecto.Changeset.t()
  def check_in_changeset(%__MODULE__{} = intake, principal_id, at),
    do: change(intake, checked_in_at: at, checked_in_by_principal_id: principal_id)

  @doc "An Intake's door check-in undone."
  @spec undo_check_in_changeset(t()) :: Ecto.Changeset.t()
  def undo_check_in_changeset(%__MODULE__{} = intake),
    do: change(intake, checked_in_at: nil, checked_in_by_principal_id: nil)

  @doc """
  An open Intake closing into a terminal `state` that carries no stamps of
  its own (ALE-385: `lapsed` and `returned` at the Payment Cutoff; ALE-391:
  `attended` and `no_show` at Attendance Finalisation, whose evidence is the
  check-in record).
  """
  @spec close_changeset(t(), String.t()) :: Ecto.Changeset.t()
  def close_changeset(%__MODULE__{} = intake, state) do
    intake
    |> change(state: state)
    |> validate_inclusion(:state, @states -- @open_states)
  end
end
