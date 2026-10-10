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

  defp validate_shape(changeset) do
    changeset
    |> validate_length(:venue, min: 1, max: @venue_max)
    |> validate_number(:capacity, greater_than: 0)
    |> validate_number(:fee_cents, greater_than: 0, less_than_or_equal_to: @fee_max_cents)
    |> validate_number(:payment_window_days, greater_than_or_equal_to: 1)
    |> validate_inclusion(:status, @statuses)
  end
end
