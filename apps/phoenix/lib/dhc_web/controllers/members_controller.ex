defmodule DhcWeb.MembersController do
  use DhcWeb, :controller

  alias Dhc.Members

  action_fallback DhcWeb.MembersHTTP

  @members_admin_roles ~w(admin president treasurer committee_coordinator sparring_coordinator workshop_coordinator beginners_coordinator quartermaster pr_manager volunteer_coordinator research_coordinator coach)

  @doc """
  GET /members
  """
  def index(conn, params) do
    case Members.list_members(params) do
      {:ok, result} ->
        conn
        |> put_view(json: DhcWeb.MembersJSON)
        |> render(:index, result: result)

      {:error, :bad_cursor} = error ->
        error

      {:error, _reason} ->
        {:error, :invalid_query}
    end
  end

  @doc """
  GET /members/insurance-form
  """
  def insurance_form(conn, _params) do
    conn
    |> put_view(json: DhcWeb.MembersJSON)
    |> render(:insurance_form, insurance_form: Members.insurance_form())
  end

  @doc "GET /members/me"
  def me(conn, _params) do
    with {:ok, user} <- Members.get_current_user(conn.assigns.current_session.principal.id) do
      conn
      |> put_view(json: DhcWeb.MembersJSON)
      |> render(:current_user, user: user, roles: conn.assigns.current_session.roles)
    end
  end

  @doc """
  GET /members/:memberId
  """
  def show(conn, %{"memberId" => member_id}) do
    with :ok <- authorize_self_or_admin(conn, member_id),
         {:ok, member} <- Members.get_member(member_id) do
      conn
      |> put_view(json: DhcWeb.MembersJSON)
      |> render(:show, member: member)
    end
  end

  @doc """
  PATCH /members/:memberId
  """
  def update(conn, %{"memberId" => member_id} = params) do
    attrs = Map.delete(params, "memberId")

    with :ok <- authorize_self_or_admin(conn, member_id),
         {:ok, member} <- Members.update_member(member_id, attrs) do
      conn
      |> put_view(json: DhcWeb.MembersJSON)
      |> render(:show, member: member)
    end
  end

  @doc """
  GET /members/analytics
  """
  def analytics(conn, _params) do
    conn
    |> put_view(json: DhcWeb.MembersJSON)
    |> render(:analytics, analytics: Members.analytics())
  end

  @doc """
  GET /options
  """
  def options(conn, _params) do
    conn
    |> put_view(json: DhcWeb.MembersJSON)
    |> render(:options, options: Members.options())
  end

  defp authorize_self_or_admin(conn, member_id) do
    current_session = conn.assigns.current_session

    if current_session.principal.id == member_id or
         Enum.any?(current_session.roles, &(&1 in @members_admin_roles)) do
      :ok
    else
      {:error, :forbidden}
    end
  end
end
