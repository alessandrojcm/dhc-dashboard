defmodule DhcWeb.MembersController do
  use DhcWeb, :controller

  alias Dhc.Members
  alias DhcWeb.ConditionalRequests

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

      {:error, :bad_cursor} ->
        bad_request(conn, "Invalid or mismatched cursor")

      {:error, _reason} ->
        bad_request(conn, "Invalid members query")
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
    case Members.get_current_user(conn.assigns.current_session.principal.id) do
      {:ok, user} ->
        conn
        |> put_view(json: DhcWeb.MembersJSON)
        |> render(:current_user, user: user, roles: conn.assigns.current_session.roles)

      {:error, :not_found} ->
        not_found(conn, "Member not found")
    end
  end

  @doc """
  GET /members/:memberId
  """
  def show(conn, %{"memberId" => member_id}) do
    with :ok <- authorize_self_or_admin(conn, member_id),
         {:ok, member} <- Members.get_member(member_id) do
      show_member(conn, member)
    else
      {:error, :forbidden} -> forbidden(conn, "Insufficient role")
      {:error, :not_found} -> not_found(conn, "Member not found")
    end
  end

  defp show_member(conn, member) do
    case ConditionalRequests.evaluate(conn, member.lock_version) do
      {:not_modified, etag} -> conn |> put_resp_header("etag", etag) |> send_resp(304, "")
      {:ok, nil} -> member_response(conn, member)
      {:ok, if_match} -> show_member_if_match(conn, member, if_match)
      {:error, reason} -> bad_request(conn, ConditionalRequests.error_detail(reason))
    end
  end

  defp show_member_if_match(conn, member, if_match) do
    if ConditionalRequests.enforce_if_match(if_match, member.lock_version) == :ok,
      do: member_response(conn, member),
      else: member_precondition_failed(conn, member)
  end

  @doc """
  PATCH /members/:memberId
  """
  def update(conn, %{"memberId" => member_id} = params) do
    attrs = Map.delete(params, "memberId")

    with :ok <- authorize_self_or_admin(conn, member_id),
         {:ok, current} <- Members.get_member(member_id),
         {:ok, opts} <- ConditionalRequests.write_options(conn),
         :ok <- verify_if_match(current, opts) do
      case Members.update_member(member_id, attrs, opts) do
        {:ok, member} ->
          member_response(conn, member)

        {:error, {:version_precondition_failed, current}} ->
          member_precondition_failed(conn, current)

        {:error, :invalid_payload} ->
          validation_error(conn, "Invalid member update payload")

        {:error, %Ecto.Changeset{} = changeset} ->
          validation_error(conn, changeset)
      end
    else
      {:error, :forbidden} -> forbidden(conn, "Insufficient role")
      {:error, :not_found} -> not_found(conn, "Member not found")
      {:error, {:precondition_failed, current}} -> member_precondition_failed(conn, current)
      {:error, reason} -> bad_request(conn, ConditionalRequests.error_detail(reason))
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

  defp member_response(conn, member) do
    conn
    |> ConditionalRequests.put_etag(member.lock_version)
    |> put_view(json: DhcWeb.MembersJSON)
    |> render(:show, member: member)
  end

  defp member_precondition_failed(conn, member) do
    conn
    |> ConditionalRequests.put_etag(member.lock_version)
    |> put_status(:precondition_failed)
    |> put_view(json: DhcWeb.MembersJSON)
    |> render(:precondition_failed, member: member)
  end

  defp verify_if_match(_current, []), do: :ok
  defp verify_if_match(_current, expected_lock_version: :*), do: :ok

  defp verify_if_match(current, expected_lock_version: expected) do
    if current.lock_version in List.wrap(expected),
      do: :ok,
      else: {:error, {:precondition_failed, current}}
  end

  defp bad_request(conn, detail) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: detail}})
  end

  defp forbidden(conn, detail) do
    conn
    |> put_status(:forbidden)
    |> json(%{errors: %{detail: detail}})
  end

  defp not_found(conn, detail) do
    conn
    |> put_status(:not_found)
    |> json(%{errors: %{detail: detail}})
  end

  defp validation_error(conn, %Ecto.Changeset{} = changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      errors: %{detail: "Invalid member update payload", fields: changeset_errors(changeset)}
    })
  end

  defp validation_error(conn, detail) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{detail: detail}})
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts
        |> Keyword.get(String.to_existing_atom(key), key)
        |> to_string()
      end)
    end)
  end
end
