defmodule DhcWeb.MemberRolesController do
  use DhcWeb, :controller

  alias Dhc.Auth.Roles

  action_fallback DhcWeb.MembersHTTP

  def show(conn, %{"memberId" => id}) do
    with {:ok, view} <- Roles.show(conn.assigns.current_session.principal.id, id) do
      render(conn, :show, view: view)
    end
  end

  def update(conn, %{"memberId" => id}) do
    with {:ok, view} <-
           Roles.update(conn.assigns.current_session.principal.id, id, conn.body_params) do
      render(conn, :show, view: view)
    end
  end
end
