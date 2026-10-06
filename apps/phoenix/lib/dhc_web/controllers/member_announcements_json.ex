defmodule DhcWeb.MemberAnnouncementsJSON do
  @moduledoc false

  alias Dhc.MemberAnnouncements.Announcement

  def render("index.json", %{announcements: rows}) do
    %{data: Enum.map(rows, &announcement(&1.announcement, &1.sent_by_name))}
  end

  def render("show.json", %{announcement: announcement, sent_by_name: name}) do
    %{data: announcement(announcement, name)}
  end

  def render("preview.json", %{preview: preview}) do
    %{
      data: %{
        html: preview.html,
        text: preview.text,
        recipientCount: preview.recipient_count
      }
    }
  end

  # Never renders the frozen recipient addresses or the email body.
  defp announcement(%Announcement{} = a, sent_by_name) do
    %{
      id: a.id,
      subject: a.subject,
      includeInactive: a.include_inactive,
      recipientCount: a.recipient_count,
      status: a.status,
      failureReason: a.failure_reason,
      sentAt: a.sent_at,
      createdAt: a.created_at,
      sentByName: sent_by_name
    }
  end
end
