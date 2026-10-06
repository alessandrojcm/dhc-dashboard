defmodule DhcWeb.MemberAnnouncementsController do
  @moduledoc """
  Member Announcements HTTP slice (ADR 0028). Gated by the
  `:member_announcements_send` pipeline; every action delegates to
  `Dhc.MemberAnnouncements`.
  """

  use DhcWeb, :controller

  alias Dhc.MemberAnnouncements

  action_fallback DhcWeb.MemberAnnouncementsHTTP

  @doc "GET /member-announcements"
  def index(conn, _params) do
    render(conn, :index, announcements: MemberAnnouncements.list_recent())
  end

  @doc "POST /member-announcements/preview"
  def preview(conn, params) do
    with {:ok, preview} <- MemberAnnouncements.preview(params) do
      render(conn, :preview, preview: preview)
    end
  end

  @doc "POST /member-announcements"
  def create(conn, params) do
    principal = conn.assigns.current_session.principal

    with {:ok, announcement} <- MemberAnnouncements.send_announcement(principal.id, params) do
      conn
      |> put_status(:accepted)
      |> render(:show, announcement: announcement, sent_by_name: nil)
    end
  end
end
