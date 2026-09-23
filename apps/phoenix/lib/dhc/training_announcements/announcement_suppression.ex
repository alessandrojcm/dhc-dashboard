defmodule Dhc.TrainingAnnouncements.AnnouncementSuppression do
  @moduledoc """
  Ecto schema for `training_announcement_suppressions`: a committee decision
  that prevents delivery for one Announcement Occurrence (`from_date ==
  to_date`) or every occurrence of one weekly Training Announcement in a
  finite, inclusive range of Europe/Dublin dates.

  Suppression dates are absolute across announcement edits; a dormant
  Suppression stays stored and may apply again after a later edit.

  Glossary (`CONTEXT.md`): "A committee decision that prevents delivery for
  either one Announcement Occurrence or every occurrence of one weekly
  Training Announcement in a finite, inclusive range of Europe/Dublin dates."
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "training_announcement_suppressions" do
    field :from_date, :date
    field :to_date, :date

    belongs_to :announcement, Dhc.TrainingAnnouncements.Announcement

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  def changeset(suppression, attrs) do
    suppression
    |> cast(attrs, [:from_date, :to_date])
    |> validate_required([:from_date, :to_date, :announcement_id])
    |> validate_range_order()
    |> foreign_key_constraint(:announcement_id)
    |> check_constraint(:from_date, name: :training_announcement_suppressions_range_check)
  end

  defp validate_range_order(changeset) do
    from = get_field(changeset, :from_date)
    to = get_field(changeset, :to_date)

    if match?(%Date{}, from) and match?(%Date{}, to) and Date.compare(from, to) == :gt do
      add_error(changeset, :to_date, "range ends before it starts")
    else
      changeset
    end
  end
end
