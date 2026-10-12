defmodule Dhc.BeginnersWorkshops.BeginnersWorkshop do
  @moduledoc """
  Ecto schema for `beginners_workshops`: one Beginners' Workshop (CONTEXT.md,
  ADR 0029). Never a Workshop; it shares no storage with `club_activities`.

  `date` and `start_time` are Europe/Dublin civil values. `payment_cutoff` is
  the instant after which no new payment can start; the boundary
  (`Dhc.BeginnersWorkshops.Commands`, which owns every write and the
  defaults) resolves it from a Dublin civil date and time. `status` is written only through the boundary's transition
  table.

  The changesets here check field *shape* only (presence, ranges, the venue
  placeholder maximum). Rules that compare fields or need the clock (the
  cutoff before the start, the contact-from date on or before the cutoff
  date, a start in the future) are named refusals in the boundary.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @statuses ~w(scheduled finalised cancelled)

  # The Intake Email `{{venue}}` placeholder maximum (ALE-372 prototype).
  @venue_max 80
  # `{{fee}}` renders at most 7 characters ("€999.99").
  @fee_max_cents 99_999

  schema "beginners_workshops" do
    field :status, :string, default: "scheduled"
    field :venue, :string
    field :date, :date
    field :start_time, :time
    field :capacity, :integer
    field :fee_cents, :integer
    field :payment_cutoff, :utc_datetime_usec
    field :contact_from, :date
    field :payment_window_days, :integer
    field :scheduled_by_principal_id, :binary_id
    # ALE-380: who paused or resumed automatic Batches last, and when.
    field :batches_paused, :boolean, default: false
    field :batches_paused_at, :utc_datetime_usec
    field :batches_paused_by_principal_id, :binary_id
    field :batches_resumed_at, :utc_datetime_usec
    field :batches_resumed_by_principal_id, :binary_id
    # ALE-391: when attendance became final, and who pressed Finish (nil
    # when the automatic end-of-day pass finalised it).
    field :finalised_at, :utc_datetime_usec
    field :finalised_by_principal_id, :binary_id
    # ALE-394: how many times it was rescheduled; names each reschedule.
    field :reschedule_count, :integer, default: 0
    # ALE-395: when the club cancelled it, who did, and the optional reason.
    field :cancelled_at, :utc_datetime_usec
    field :cancelled_by_principal_id, :binary_id
    field :cancel_reason, :string

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @doc "Every workshop status."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The venue's maximum length (the `{{venue}}` placeholder maximum)."
  @spec venue_max() :: pos_integer()
  def venue_max, do: @venue_max

  @doc """
  The shape of a new workshop. `attrs` are already resolved by the boundary
  (defaults filled, the cutoff an instant).
  """
  @spec schedule_changeset(map()) :: Ecto.Changeset.t()
  def schedule_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :venue,
      :date,
      :start_time,
      :capacity,
      :fee_cents,
      :payment_cutoff,
      :contact_from,
      :payment_window_days,
      :scheduled_by_principal_id
    ])
    |> update_change(:venue, &String.trim/1)
    |> validate_required([
      :venue,
      :date,
      :start_time,
      :capacity,
      :fee_cents,
      :payment_cutoff,
      :contact_from,
      :payment_window_days
    ])
    |> validate_shape()
  end

  @doc "The shape of a settings update (`update_workshop`)."
  @spec settings_changeset(t(), map()) :: Ecto.Changeset.t()
  def settings_changeset(%__MODULE__{} = workshop, attrs) do
    workshop
    |> cast(attrs, [:capacity, :fee_cents, :payment_cutoff, :contact_from, :payment_window_days])
    |> validate_required([
      :capacity,
      :fee_cents,
      :payment_cutoff,
      :contact_from,
      :payment_window_days
    ])
    |> validate_shape()
  end

  @doc """
  The shape of a reschedule (`reschedule_workshop`, ALE-394): the new date,
  start time, venue, Payment Cutoff and contact-from date, already resolved
  by the boundary, and the next reschedule number.
  """
  @spec reschedule_changeset(t(), map()) :: Ecto.Changeset.t()
  def reschedule_changeset(%__MODULE__{} = workshop, attrs) do
    workshop
    |> cast(attrs, [:venue, :date, :start_time, :payment_cutoff, :contact_from])
    |> update_change(:venue, &String.trim/1)
    |> validate_required([:venue, :date, :start_time, :payment_cutoff, :contact_from])
    |> change(reschedule_count: workshop.reschedule_count + 1)
    |> validate_shape()
  end

  @doc "Pauses automatic Batches (`pause_batches`), recording who and when."
  @spec pause_changeset(t(), binary(), DateTime.t()) :: Ecto.Changeset.t()
  def pause_changeset(%__MODULE__{} = workshop, principal_id, at),
    do:
      change(workshop,
        batches_paused: true,
        batches_paused_at: usec(at),
        batches_paused_by_principal_id: principal_id
      )

  @doc "Resumes automatic Batches (`resume_batches`), recording who and when."
  @spec resume_changeset(t(), binary(), DateTime.t()) :: Ecto.Changeset.t()
  def resume_changeset(%__MODULE__{} = workshop, principal_id, at) do
    change(workshop,
      batches_paused: false,
      batches_resumed_at: usec(at),
      batches_resumed_by_principal_id: principal_id
    )
  end

  @doc """
  Attendance Finalisation (`finish_workshop` / `finalise_attendance`): the
  status change with when, and who (`nil` for the automatic pass).
  """
  @spec finalise_changeset(t(), binary() | nil, DateTime.t()) :: Ecto.Changeset.t()
  def finalise_changeset(%__MODULE__{} = workshop, principal_id, at),
    do:
      change(workshop,
        status: "finalised",
        finalised_at: usec(at),
        finalised_by_principal_id: principal_id
      )

  @doc """
  Cancellation (`cancel_workshop`, ALE-395): the status change with when,
  who, and the optional reason.
  """
  @spec cancel_changeset(t(), binary(), String.t() | nil, DateTime.t()) :: Ecto.Changeset.t()
  def cancel_changeset(%__MODULE__{} = workshop, principal_id, reason, at),
    do:
      change(workshop,
        status: "cancelled",
        cancelled_at: usec(at),
        cancelled_by_principal_id: principal_id,
        cancel_reason: reason
      )

  defp usec(%DateTime{microsecond: {value, _precision}} = at),
    do: %{at | microsecond: {value, 6}}

  defp validate_shape(changeset) do
    changeset
    |> validate_length(:venue, min: 1, max: @venue_max)
    |> validate_number(:capacity, greater_than: 0)
    |> validate_number(:fee_cents, greater_than: 0, less_than_or_equal_to: @fee_max_cents)
    |> validate_number(:payment_window_days, greater_than_or_equal_to: 1)
    |> validate_inclusion(:status, @statuses)
  end
end
