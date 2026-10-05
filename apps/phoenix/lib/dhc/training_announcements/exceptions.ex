defmodule Dhc.TrainingAnnouncements.Exceptions do
  @moduledoc "Internal dated-exception persistence; callers hold Store.with_current's claim."
  import Ecto.Query

  alias Dhc.ClubCalendar
  alias Dhc.Repo
  alias Dhc.TrainingAnnouncements.AnnouncementOverride
  alias Dhc.TrainingAnnouncements.AnnouncementSuppression
  alias Dhc.TrainingAnnouncements.Copy
  alias Dhc.TrainingAnnouncements.DiscordAnnouncementDelivery

  def create(announcement, kind, attrs, now) do
    schema = schema(kind)

    schema
    |> struct(announcement_id: announcement.id)
    |> schema.changeset(attrs)
    |> validate_dates(announcement, now)
    |> validate_rendered_copy(announcement, kind)
    |> Repo.insert()
  end

  def list(id, kind) do
    schema = schema(kind)

    Repo.all(
      from(e in schema,
        where: e.announcement_id == ^id,
        order_by: [asc: e.from_date, asc: e.created_at, asc: e.id]
      )
    )
  end

  def remove(id, kind, exception_id) do
    schema = schema(kind)

    with {:ok, exception_id} <- Ecto.UUID.cast(exception_id),
         exception when not is_nil(exception) <-
           Repo.one(
             from(e in schema,
               where: e.announcement_id == ^id and e.id == ^exception_id
             )
           ) do
      Repo.delete(exception)
    else
      _ -> {:error, :not_found}
    end
  end

  defp schema(:suppression), do: AnnouncementSuppression
  defp schema(:override), do: AnnouncementOverride

  defp validate_dates(%{valid?: false} = changeset, _announcement, _now), do: changeset

  defp validate_dates(changeset, announcement, now) do
    exception = Ecto.Changeset.apply_changes(changeset)
    today = ClubCalendar.on_date(now)

    begun? =
      Repo.exists?(
        from(d in DiscordAnnouncementDelivery,
          where:
            d.announcement_id == ^announcement.id and
              d.occurrence_date >= ^exception.from_date and
              d.occurrence_date <= ^exception.to_date and
              not is_nil(d.frozen_at)
        )
      )

    cond do
      Date.compare(exception.from_date, today) == :lt ->
        Ecto.Changeset.add_error(changeset, :from_date, "must be today or later in Dublin")

      begun? ->
        Ecto.Changeset.add_error(
          changeset,
          :from_date,
          "delivery has already begun in this range"
        )

      is_nil(announcement.weekday) and exception.from_date != exception.to_date ->
        Ecto.Changeset.add_error(
          changeset,
          :to_date,
          "a one-off exception must cover a single date"
        )

      true ->
        changeset
    end
  end

  defp validate_rendered_copy(%{valid?: false} = changeset, _announcement, _kind), do: changeset
  defp validate_rendered_copy(changeset, _announcement, :suppression), do: changeset

  defp validate_rendered_copy(changeset, announcement, :override) do
    exception = Ecto.Changeset.apply_changes(changeset)

    copy = %{
      title: exception.title || announcement.title,
      message: exception.message || announcement.message,
      mention_everyone: announcement.mention_everyone
    }

    # Even dormant ranges must be safe when a later schedule moves onto them.
    # Tokens contain no year. A civil year includes the longest weekday/month
    # and two-digit day expansions together; longer ranges add no length cases.
    last =
      if Date.diff(exception.to_date, exception.from_date) > 366,
        do: Date.add(exception.from_date, 366),
        else: exception.to_date

    Enum.reduce_while(Date.range(exception.from_date, last), changeset, fn date, acc ->
      case Copy.render(copy, date) do
        {:ok, _} ->
          {:cont, acc}

        {:error, errors} ->
          {:halt, Ecto.Changeset.add_error(acc, :message, Enum.join(errors, ", "))}
      end
    end)
  end
end
