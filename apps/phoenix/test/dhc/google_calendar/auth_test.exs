defmodule Dhc.GoogleCalendar.AuthTest do
  use ExUnit.Case, async: false

  alias Dhc.GoogleCalendar.Auth

  @scopes "https://www.googleapis.com/auth/calendar.events.owned https://www.googleapis.com/auth/calendar.acls"

  setup do
    previous = Application.get_env(:dhc, Auth)

    Application.put_env(:dhc, Auth,
      client_id: "calendar-client",
      client_secret: "PRIVATE-secret",
      refresh_token: "PRIVATE-refresh",
      req_options: [plug: {Req.Test, Auth}]
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:dhc, Auth, previous),
        else: Application.delete_env(:dhc, Auth)
    end)
  end

  test "exchanges the one organizer grant and accepts both scopes in either order" do
    Req.Test.expect(Auth, fn conn ->
      assert conn.method == "POST"
      assert conn.host == "oauth2.googleapis.com"
      assert conn.request_path == "/token"

      assert conn.body_params == %{
               "grant_type" => "refresh_token",
               "client_id" => "calendar-client",
               "client_secret" => "PRIVATE-secret",
               "refresh_token" => "PRIVATE-refresh"
             }

      Req.Test.json(conn, %{
        "access_token" => "short-lived",
        "scope" => @scopes |> String.split() |> Enum.reverse() |> Enum.join(" ")
      })
    end)

    assert {:ok, "short-lived"} = Auth.access_token()
  end

  test "checks loaded credentials without returning tokens and distinguishes actionable failures" do
    for {status, body, expected} <- [
          {200, %{"access_token" => "PRIVATE-access", "scope" => @scopes}, :ok},
          {401, %{"error" => "invalid_client"}, {:error, :invalid_client}},
          {400, %{"error" => "invalid_client"}, {:error, :invalid_client}},
          {400, %{"error" => "invalid_grant"}, {:error, :reauthorization_required}},
          {400, %{"error" => "invalid_scope"}, {:error, :missing_permissions}},
          {403, %{"error" => "access_denied"}, {:error, :reauthorization_required}},
          {429, %{}, {:error, :transient}},
          {503, %{}, {:error, :transient}},
          {400, %{"error" => "PRIVATE-unknown"}, {:error, :configuration}}
        ] do
      Req.Test.expect(Auth, fn conn ->
        conn
        |> Plug.Conn.put_status(status)
        |> Req.Test.json(Map.put(body, "error_description", "PRIVATE-provider-body"))
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Auth.check() == expected
        end)

      refute log =~ "PRIVATE"
    end
  end

  test "requires both scopes, refuses broader grants and rejects malformed acknowledgments" do
    for {body, reason} <- [
          {%{"access_token" => "access"}, :missing_permissions},
          {%{"access_token" => "access", "scope" => []}, :missing_permissions},
          {%{
             "access_token" => "access",
             "scope" => "https://www.googleapis.com/auth/calendar.acls"
           }, :missing_permissions},
          {%{
             "access_token" => "access",
             "scope" => "https://www.googleapis.com/auth/calendar.events.owned"
           }, :missing_permissions},
          {%{"access_token" => "access", "scope" => @scopes <> " extra"},
           :unexpected_permissions},
          {%{"access_token" => "", "scope" => @scopes}, :configuration},
          {%{}, :configuration}
        ] do
      Req.Test.expect(Auth, &Req.Test.json(&1, body))
      assert {:error, ^reason} = Auth.access_token()
    end
  end

  test "missing loaded credentials fail without an HTTP request or fallback to feature credentials" do
    for key <- [:client_id, :client_secret, :refresh_token], value <- [nil, "", " "] do
      original = Application.fetch_env!(:dhc, Auth)
      Application.put_env(:dhc, Auth, Keyword.put(original, key, value))
      assert {:error, :configuration} = Auth.client_id()
      assert {:error, :configuration} = Auth.check()
      Application.put_env(:dhc, Auth, original)
    end

    assert {:ok, "calendar-client"} = Auth.client_id()
  end

  test "transport failures are transient and never escape as exception metadata" do
    Req.Test.expect(Auth, &Req.Test.transport_error(&1, :timeout))
    assert {:error, :transient} = Auth.access_token()
  end
end
