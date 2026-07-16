defmodule DhcWeb.NotificationsJSON do
  @moduledoc false

  def render("list.json", %{result: result}) do
    %{
      data: %{
        notifications: Enum.map(result.notifications, &notification/1),
        unreadCount: result.unread_count,
        nextCursor: result.next_cursor
      }
    }
  end

  def render("show.json", %{notification: notification}) do
    %{data: notification(notification)}
  end

  def render("mark_all_read.json", %{updated_count: updated_count}) do
    %{data: %{updatedCount: updated_count}}
  end

  defp notification(notification) do
    %{
      id: notification.id,
      body: notification.body,
      createdAt: notification.created_at,
      readAt: notification.read_at
    }
  end
end
