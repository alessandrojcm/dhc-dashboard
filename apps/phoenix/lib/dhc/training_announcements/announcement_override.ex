defmodule Dhc.TrainingAnnouncements.AnnouncementOverride do
  @moduledoc """
  Ecto schema for `training_announcement_overrides`: a replacement title,
  message, or both for one Announcement Occurrence (`from_date == to_date`)
  or a finite, inclusive range of one weekly Training Announcement's
  Europe/Dublin dates.

  An announcement's Override ranges never overlap — the GiST exclusion
  `training_announcement_overrides_no_overlap` rejects ambiguity at the
  database, so the resolved copy is never a race between two rows. Ranges
  stay bound to absolute dates across schedule edits; an Override with no
  current occurrence stays dormant and may apply again after a later edit.

  Glossary (`CONTEXT.md`): "A replacement title, message, or both for one
  Announcement Occurrence or a finite, inclusive range of one weekly Training
  Announcement's Europe/Dublin dates."
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Dhc.TrainingAnnouncements.Copy

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "training_announcement_overrides" do
    field :from_date, :date
    field :to_date, :date
    field :title, :string
    field :message, :string

    belongs_to :announcement, Dhc.TrainingAnnouncements.Announcement

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  def changeset(override, attrs) do
    override
    |> cast(attrs, [:from_date, :to_date, :title, :message])
    |> validate_required([:from_date, :to_date, :announcement_id])
    |> validate_range_order()
    |> validate_content_present()
    |> validate_copy()
    |> validate_length(:title, max: 100)
    |> validate_length(:message, max: 2000)
    |> foreign_key_constraint(:announcement_id)
    |> check_constraint(:from_date, name: :training_announcement_overrides_range_check)
    |> check_constraint(:title, name: :training_announcement_overrides_content_check)
    |> exclusion_constraint(:from_date,
      name: :training_announcement_overrides_no_overlap,
      message: "overlaps another override for this announcement"
    )
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

  defp validate_content_present(changeset) do
    title = get_field(changeset, :title)
    message = get_field(changeset, :message)

    if is_nil(title) and is_nil(message) do
      add_error(changeset, :title, "an override replaces the title, the message, or both")
    else
      changeset
    end
  end

  defp validate_copy(changeset) do
    changeset
    |> validate_change(:title, fn :title, title when is_binary(title) ->
      case Copy.validate_title(title) do
        :ok -> []
        {:error, errors} -> [title: Enum.join(errors, ", ")]
      end
    end)
    |> validate_change(:message, fn :message, message when is_binary(message) ->
      case Copy.validate_message(message) do
        :ok -> []
        {:error, errors} -> [message: Enum.join(errors, ", ")]
      end
    end)
  end
end
