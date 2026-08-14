defmodule DhcWeb.E2EHarnessController do
  @moduledoc false

  use DhcWeb, :controller

  import Plug.Conn

  alias Dhc.E2EHarness

  def reset(conn, _params) do
    with_harness(conn, fn conn ->
      :ok = E2EHarness.reset!()
      json(conn, %{data: %{reset: true}})
    end)
  end

  def seed(conn, %{"scenario" => scenario} = params) do
    with_harness(conn, fn conn ->
      case E2EHarness.seed(scenario, Map.get(params, "attrs", %{})) do
        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: %{detail: inspect(reason)}})

        data ->
          json(conn, %{data: data})
      end
    end)
  end

  def login(conn, %{"email" => email}) do
    with_harness(conn, fn conn ->
      token = E2EHarness.login_cookie(email)

      conn
      |> put_resp_cookie("_dhc_session", token,
        sign: true,
        http_only: true,
        secure: false,
        same_site: "Lax",
        path: "/",
        max_age: 30 * 24 * 60 * 60
      )
      |> json(%{data: %{authenticated: true}})
    end)
  end

  def invitation_acceptance_audit(conn, %{"id" => invitation_id}) do
    with_harness(conn, fn conn ->
      json(conn, %{data: E2EHarness.invitation_acceptance_audit(invitation_id)})
    end)
  end

  def interrupt_next_finalization(conn, _params) do
    with_harness(conn, fn conn ->
      :ok = E2EHarness.interrupt_next_finalization!()
      json(conn, %{data: %{armed: true}})
    end)
  end

  def delete_fixture(conn, %{"type" => type, "id" => id}) do
    with_harness(conn, fn conn ->
      E2EHarness.delete_fixture(type, id)
      json(conn, %{data: %{deleted: true}})
    end)
  end

  def update_fixture(conn, %{"type" => type, "id" => id} = params) do
    with_harness(conn, fn conn ->
      data = E2EHarness.update_fixture(type, id, Map.get(params, "attrs", %{}))
      json(conn, %{data: data})
    end)
  end

  defp with_harness(conn, callback) do
    expected = Application.fetch_env!(:dhc, :e2e_harness_key)

    case get_req_header(conn, "x-e2e-harness-key") do
      [^expected] -> callback.(conn)
      _ -> conn |> put_status(:not_found) |> json(%{errors: %{detail: "Not found"}})
    end
  end
end
