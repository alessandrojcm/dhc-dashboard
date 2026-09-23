defmodule Dhc.TrainingAnnouncements.Announcement do
  @moduledoc """
  Ecto schema for the `training_announcements` table: one Training
  Announcement of kind `roll_call | sparring`, either weekly (one weekday,
  Monday = 1 .. Sunday = 7) or one-off (one Europe/Dublin date), with exactly
  one `post_time` in Europe/Dublin civil time. The post time is the send
  time; there is no end time, duration, or lead time.

  `kind` never changes after creation: the create changeset casts it, the
  update changeset rejects any change to it. `first_attempted_at` is stamped
  once by the delivery path on the first frozen delivery and never cleared —
  it (not the delivery rows) guards deletion of attempted announcements, so
  pruning cannot make an attempted announcement deletable.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Dhc.TrainingAnnouncements.Copy

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @kinds ~w(roll_call sparring)

  schema "training_announcements" do
    field :kind, :string
    field :weekday, :integer
    field :one_off_date, :date
    field :post_time, :time
    field :title, :string
    field :message, :string
    field :mention_everyone, :boolean, default: false
    field :enabled, :boolean, default: true
    field :retired, :boolean, default: false
    field :first_attempted_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @doc "Changeset for creating an announcement. The only changeset that casts `:kind`."
  def create_changeset(announcement, attrs) do
    announcement
    |> cast(attrs, [
      :kind,
      :weekday,
      :one_off_date,
      :post_time,
      :title,
      :message,
      :mention_everyone,
      :enabled
    ])
    |> validate_required([:kind, :post_time, :title, :message])
    |> validate_inclusion(:kind, @kinds)
    |> validate_schedule_shape()
    |> validate_copy()
    |> validate_length(:title, max: 100)
    |> validate_length(:message, max: 2000)
    |> check_constraint(:kind, name: :training_announcements_kind_check)
    |> check_constraint(:weekday, name: :training_announcements_weekday_check)
    |> check_constraint(:one_off_date, name: :training_announcements_schedule_shape_check)
    |> check_constraint(:title, name: :training_announcements_title_check)
    |> check_constraint(:message, name: :training_announcements_message_check)
  end

  @doc """
  Changeset for schedule and copy edits. Never casts `:kind`: a kind change
  in the attributes is rejected so a roll call cannot become a sparring post.
  """
  def update_changeset(announcement, attrs) do
    attrs = Map.new(attrs)

    announcement
    |> cast(attrs, [
      :weekday,
      :one_off_date,
      :post_time,
      :title,
      :message,
      :mention_everyone,
      :enabled
    ])
    |> reject_kind_change(attrs)
    |> validate_required([:post_time, :title, :message])
    |> validate_schedule_shape()
    |> validate_copy()
    |> validate_length(:title, max: 100)
    |> validate_length(:message, max: 2000)
    |> check_constraint(:weekday, name: :training_announcements_weekday_check)
    |> check_constraint(:one_off_date, name: :training_announcements_schedule_shape_check)
    |> check_constraint(:title, name: :training_announcements_title_check)
    |> check_constraint(:message, name: :training_announcements_message_check)
  end

  defp reject_kind_change(changeset, attrs) do
    stringified = for {key, value} <- attrs, into: %{}, do: {to_string(key), value}

    case Map.get(stringified, "kind") do
      nil ->
        changeset

      kind when kind == changeset.data.kind ->
        changeset

      _ ->
        add_error(changeset, :kind, "kind never changes after creation")
    end
  end

  defp validate_schedule_shape(changeset) do
    weekday = get_field(changeset, :weekday)
    one_off_date = get_field(changeset, :one_off_date)

    changeset
    |> validate_inclusion(:weekday, 1..7)
    |> then(fn changeset ->
      if is_nil(weekday) == is_nil(one_off_date) do
        add_error(
          changeset,
          :one_off_date,
          "weekly announcements set a weekday, one-offs set a date"
        )
      else
        changeset
      end
    end)
  end

  defp validate_copy(changeset) do
    changeset
    |> validate_change(:title, fn :title, title ->
      case Copy.validate_title(title) do
        :ok -> []
        {:error, errors} -> [title: Enum.join(errors, ", ")]
      end
    end)
    |> validate_change(:message, fn :message, message ->
      case Copy.validate_message(message) do
        :ok -> []
        {:error, errors} -> [message: Enum.join(errors, ", ")]
      end
    end)
  end
end
