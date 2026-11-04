defmodule Dhc.WorkshopCalendar.GoogleTest do
  use ExUnit.Case, async: false

  alias Dhc.WorkshopCalendar.Google

  @scope "https://www.googleapis.com/auth/calendar.events.owned"

  setup do
    original = Application.get_env(:dhc, Dhc.WorkshopCalendar)

    Application.put_env(:dhc, Dhc.WorkshopCalendar,
      client_id: "organizer-client",
      client_secret: "organizer-secret",
      refresh_token: "organizer-refresh-token",
      req_options: [plug: {Req.Test, Dhc.WorkshopCalendar.Google}]
    )

    on_exit(fn -> restore_config(original) end)
    :ok
  end

  test "refreshes the dedicated organizer credential and gets an event" do
    Req.Test.expect(Dhc.WorkshopCalendar.Google, 2, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/token"} ->
          assert conn.body_params == %{
                   "client_id" => "organizer-client",
                   "client_secret" => "organizer-secret",
                   "grant_type" => "refresh_token",
                   "refresh_token" => "organizer-refresh-token",
                   "scope" => @scope
                 }

          Req.Test.json(conn, %{"access_token" => "short-lived", "scope" => @scope})

        {"GET", "/calendar/v3/calendars/committee%40example.com/events/event-1"} ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer short-lived"]
          Req.Test.json(conn, %{"id" => "event-1", "etag" => "etag-1"})
      end
    end)

    assert {:ok, %{"id" => "event-1", "etag" => "etag-1"}} =
             Google.get("committee@example.com", "event-1")
  end

  test "rejects an OAuth response whose declared scope does not include the owned-events scope" do
    Req.Test.stub(Dhc.WorkshopCalendar.Google, fn conn ->
      Req.Test.json(conn, %{"access_token" => "short-lived", "scope" => "calendar.readonly"})
    end)

    assert {:error, :configuration} = Google.get("committee", "event-1")
  end

  test "rejects an OAuth response whose declared scope includes any broader permission" do
    Req.Test.stub(Dhc.WorkshopCalendar.Google, fn conn ->
      Req.Test.json(conn, %{
        "access_token" => "short-lived",
        "scope" => @scope <> " https://www.googleapis.com/auth/calendar"
      })
    end)

    assert {:error, :configuration} = Google.get("committee", "event-1")
  end

  test "checks an accessible calendar without treating an empty event list as absent" do
    Req.Test.expect(Dhc.WorkshopCalendar.Google, 2, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/token"} ->
          Req.Test.json(conn, %{"access_token" => "short-lived"})

        {"GET", "/calendar/v3/calendars/committee/events"} ->
          assert conn.query_params == %{"fields" => "kind", "maxResults" => "1"}
          Req.Test.json(conn, %{"kind" => "calendar#events"})
      end
    end)

    assert :ok = Google.check_calendar("committee")
  end

  test "treats an inaccessible or absent calendar as configuration, not an absent event" do
    Req.Test.expect(Dhc.WorkshopCalendar.Google, 2, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/token"} -> Req.Test.json(conn, %{"access_token" => "short-lived"})
        {"GET", "/calendar/v3/calendars/missing/events"} -> Plug.Conn.send_resp(conn, 404, "")
      end
    end)

    assert {:error, :configuration} = Google.check_calendar("missing")
  end

  test "inserts a committee event without attendees or updates" do
    Req.Test.expect(Dhc.WorkshopCalendar.Google, 2, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/token"} ->
          Req.Test.json(conn, %{"access_token" => "short-lived"})

        {"POST", "/calendar/v3/calendars/committee/events"} ->
          assert conn.query_string == "sendUpdates=none"
          refute Map.has_key?(conn.body_params, "attendees")
          Req.Test.json(conn, %{"id" => "event-1"})
      end
    end)

    assert {:ok, %{"id" => "event-1"}} = Google.insert("committee", %{"summary" => "Workshop"})
  end

  test "uses If-Match and sendUpdates=none for updates and deletes" do
    Req.Test.expect(Dhc.WorkshopCalendar.Google, 4, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/token"} ->
          Req.Test.json(conn, %{"access_token" => "short-lived"})

        {"PUT", "/calendar/v3/calendars/committee/events/event-1"} ->
          assert conn.query_string == "sendUpdates=none"
          assert Plug.Conn.get_req_header(conn, "if-match") == ["etag-1"]
          Req.Test.json(conn, %{"id" => "event-1", "etag" => "etag-2"})

        {"DELETE", "/calendar/v3/calendars/committee/events/event-1"} ->
          assert conn.query_string == "sendUpdates=none"
          assert Plug.Conn.get_req_header(conn, "if-match") == ["etag-2"]
          Plug.Conn.send_resp(conn, 204, "")
      end
    end)

    assert {:ok, %{"etag" => "etag-2"}} =
             Google.update("committee", "event-1", %{"summary" => "Moved"}, "etag-1")

    assert {:ok, :deleted} = Google.delete("committee", "event-1", "etag-2")
  end

  test "maps provider and transport outcomes to safe domain atoms" do
    for {status, body, expected} <- [
          {401, %{}, :unauthorized},
          {404, %{}, :missing},
          {410, %{}, :gone},
          {409, %{}, :conflict},
          {412, %{}, :conflict},
          {429, %{}, :transient},
          {500, %{}, :transient},
          {403, %{"error" => %{"errors" => [%{"reason" => "rateLimitExceeded"}]}}, :transient},
          {403, %{}, :configuration}
        ] do
      Req.Test.stub(Dhc.WorkshopCalendar.Google, fn conn ->
        if conn.request_path == "/token" do
          Req.Test.json(conn, %{"access_token" => "short-lived"})
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(status, Jason.encode!(body))
        end
      end)

      assert {:error, ^expected} = Google.get("committee", "event-1")
    end

    Req.Test.stub(Dhc.WorkshopCalendar.Google, fn conn ->
      if conn.request_path == "/token" do
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => "invalid_grant"}))
      else
        Req.Test.transport_error(conn, :econnrefused)
      end
    end)

    assert {:error, :unauthorized} = Google.get("committee", "event-1")

    Req.Test.stub(Dhc.WorkshopCalendar.Google, fn conn ->
      if conn.request_path == "/token" do
        Req.Test.json(conn, %{"access_token" => "short-lived"})
      else
        Req.Test.transport_error(conn, :econnrefused)
      end
    end)

    assert {:error, :transient} = Google.get("committee", "event-1")
  end

  test "permits only an empty attendee list so mutations can remove provider-added attendees" do
    Req.Test.expect(Dhc.WorkshopCalendar.Google, 2, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/token"} ->
          Req.Test.json(conn, %{"access_token" => "short-lived"})

        {"POST", "/calendar/v3/calendars/committee/events"} ->
          Req.Test.json(conn, %{"id" => "event-1"})
      end
    end)

    assert {:ok, %{"id" => "event-1"}} =
             Google.insert("committee", %{"summary" => "Workshop", "attendees" => []})

    assert {:error, :rejected} =
             Google.insert("committee", %{"attendees" => [%{"email" => "x@example.com"}]})

    assert {:error, :rejected} =
             Google.insert("committee", %{attendees: [%{email: "x@example.com"}]})
  end

  test "rechecks mutation facts after refresh and before issuing the Calendar request" do
    Req.Test.expect(Dhc.WorkshopCalendar.Google, fn conn ->
      assert {"POST", "/token"} == {conn.method, conn.request_path}
      Req.Test.json(conn, %{"access_token" => "short-lived"})
    end)

    assert {:skip, :paused} =
             Google.insert("committee", %{"summary" => "Workshop"},
               before_mutation: fn -> {:skip, :paused} end
             )
  end

  test "provider credential errors expose neither credentials nor response bodies in logs" do
    Req.Test.stub(Google, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{
        "error" => "invalid_grant",
        "error_description" => "PRIVATE provider response"
      })
    end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :unauthorized} = Google.get("committee", "event-1")
      end)

    for forbidden <- ["organizer-secret", "organizer-refresh-token", "PRIVATE provider response"] do
      refute log =~ forbidden
    end
  end

  defp restore_config(nil), do: Application.delete_env(:dhc, Dhc.WorkshopCalendar)
  defp restore_config(config), do: Application.put_env(:dhc, Dhc.WorkshopCalendar, config)
end
