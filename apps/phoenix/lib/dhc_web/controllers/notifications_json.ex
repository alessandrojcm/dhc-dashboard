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

  defp notification(notification) do
    %{
      id: notification.id,
      body: notification.body,
      createdAt: notification.created_at,
      readAt: notification.read_at
    }
  end
end
