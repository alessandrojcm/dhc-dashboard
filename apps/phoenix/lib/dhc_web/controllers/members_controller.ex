defmodule DhcWeb.MembersController do
  use DhcWeb, :controller

  alias Dhc.Members

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

  @doc """
  GET /members/analytics
  """
  def analytics(conn, _params) do
    conn
    |> put_view(json: DhcWeb.MembersJSON)
    |> render(:analytics, analytics: Members.analytics())
  end

  defp bad_request(conn, detail) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: detail}})
  end
end
