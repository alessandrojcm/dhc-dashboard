defmodule DhcWeb.TrainingAnnouncementsJSON do
  def index(%{result: announcements}), do: %{data: Enum.map(announcements, &announcement/1)}
  def show(%{result: row}), do: %{data: announcement(row)}

  def schedule(%{result: %{announcement: row, warnings: warnings}}),
    do: %{data: %{announcement: announcement(row), warnings: warnings}}

  def preview(%{result: copy}),
    do: %{data: %{threadName: copy.thread_name, renderedMessage: copy.rendered_message}}

  def suppressions(%{result: rows}), do: %{data: Enum.map(rows, &suppression_data/1)}
  def overrides(%{result: rows}), do: %{data: Enum.map(rows, &override_data/1)}
  def suppression(%{result: row}), do: %{data: suppression_data(row)}
  def override(%{result: row}), do: %{data: override_data(row)}

  defp announcement(row) do
    %{
      id: row.id,
      kind: row.kind,
      weekday: row.weekday,
      oneOffDate: row.one_off_date,
      postTime: Time.to_iso8601(row.post_time),
      title: row.title,
      message: row.message,
      mentionEveryone: row.mention_everyone,
      enabled: row.enabled,
      retired: row.retired,
      firstAttemptedAt: row.first_attempted_at,
      createdAt: row.created_at,
      updatedAt: row.updated_at
    }
  end

  defp suppression_data(row),
    do: %{
      id: row.id,
      announcementId: row.announcement_id,
      fromDate: row.from_date,
      toDate: row.to_date,
      createdAt: row.created_at
    }

  defp override_data(row),
    do: Map.merge(suppression_data(row), %{title: row.title, message: row.message})
end
