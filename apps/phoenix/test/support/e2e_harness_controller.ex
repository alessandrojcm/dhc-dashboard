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

  def interrupt_next_finalization(conn, %{"invitationId" => invitation_id}) do
    with_harness(conn, fn conn ->
      :ok = E2EHarness.interrupt_next_finalization!(invitation_id)
      json(conn, %{data: %{armed: true}})
    end)
  end

  def start_onboarding_isolation_probe(conn, _params) do
    with_harness(conn, fn conn ->
      :ok = E2EHarness.start_onboarding_isolation_probe()
      json(conn, %{data: %{started: true}})
    end)
  end

  def invitation_acceptance_assertion(conn, %{"id" => invitation_id}) do
    with_harness(conn, fn conn ->
      json(conn, %{data: E2EHarness.invitation_acceptance_assertion(invitation_id)})
    end)
  end

  def status(conn, _params) do
    with_harness(conn, fn conn ->
      json(conn, %{data: E2EHarness.status()})
    end)
  end

  def run_loan_reminders(conn, params) do
    with_harness(conn, fn conn ->
      json(conn, %{data: E2EHarness.run_loan_reminders(Map.get(params, "attrs", %{}))})
    end)
  end

  def clear_finalization_interruption(conn, %{"invitationId" => invitation_id}) do
    with_harness(conn, fn conn ->
      :ok = E2EHarness.clear_finalization_interruption!(invitation_id)
      json(conn, %{data: %{cleared: true}})
    end)
  end

  def delete_fixture(conn, %{"type" => type, "id" => id}) do
    with_harness(conn, fn conn ->
      type
      |> E2EHarness.delete_fixture(id)
      |> delete_fixture_response(conn)
    end)
  end

  def update_fixture(conn, %{"type" => type, "id" => id} = params) do
    with_harness(conn, fn conn ->
      data = E2EHarness.update_fixture(type, id, Map.get(params, "attrs", %{}))
      json(conn, %{data: data})
    end)
  end

  defp delete_fixture_response(:ok, conn), do: json(conn, %{data: %{deleted: true}})
  defp delete_fixture_response({:ok, _}, conn), do: json(conn, %{data: %{deleted: true}})

  defp delete_fixture_response({:error, :still_referenced}, conn) do
    conn
    |> put_status(:conflict)
    |> json(%{errors: %{detail: "still_referenced"}})
  end

  defp delete_fixture_response({:error, :still_referenced, details}, conn) do
    conn
    |> put_status(:conflict)
    |> json(%{errors: still_referenced_errors(details)})
  end

  defp delete_fixture_response({:error, :not_found}, conn) do
    conn
    |> put_status(:not_found)
    |> json(%{errors: %{detail: "not_found"}})
  end

  defp delete_fixture_response({:error, reason}, conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{detail: inspect(reason)}})
  end

  defp delete_fixture_response({:error, reason, _details}, conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{detail: inspect(reason)}})
  end

  defp still_referenced_errors(details) when is_map(details) do
    count = Map.get(details, :active_value_count) || Map.get(details, "active_value_count")

    if is_integer(count) do
      %{detail: "still_referenced", activeValueCount: count}
    else
      %{detail: "still_referenced"}
    end
  end

  defp still_referenced_errors(_details), do: %{detail: "still_referenced"}

  defp with_harness(conn, callback) do
    expected = Application.fetch_env!(:dhc, :e2e_harness_key)

    case get_req_header(conn, "x-e2e-harness-key") do
      [^expected] -> callback.(conn)
      _ -> conn |> put_status(:not_found) |> json(%{errors: %{detail: "Not found"}})
    end
  end
end
