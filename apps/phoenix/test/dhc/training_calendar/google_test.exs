defmodule Dhc.TrainingCalendar.GoogleTest do
  use ExUnit.Case, async: false

  alias Dhc.TrainingCalendar.Google

  @scope "https://www.googleapis.com/auth/calendar.acls"

  setup do
    original = Application.get_env(:dhc, Dhc.TrainingCalendar)

    Application.put_env(:dhc, Dhc.TrainingCalendar,
      client_id: "training-client",
      client_secret: "training-secret",
      refresh_token: "training-refresh-token",
      req_options: [plug: {Req.Test, Dhc.TrainingCalendar.Google}]
    )

    on_exit(fn -> restore_config(original) end)
    :ok
  end

  test "lists all ACL pages with one token exchange" do
    Req.Test.expect(Google, 3, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/token"} ->
          assert conn.body_params["scope"] == @scope
          Req.Test.json(conn, %{"access_token" => "short-lived", "scope" => @scope})

        {"GET", "/calendar/v3/calendars/training/acl"} ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer short-lived"]
          assert conn.query_params["maxResults"] == "250"

          case conn.query_params do
            %{"maxResults" => "250", "pageToken" => "second"} ->
              list_json(conn, %{"items" => [default_rule("two")]})

            %{"maxResults" => "250"} ->
              list_json(conn, %{"items" => [user_rule("one")], "nextPageToken" => "second"})
          end
      end
    end)

    assert {:ok, [first, second]} = Google.list("training")
    assert first["id"] == "one"
    assert second["scope"]["type"] == "default"
  end

  test "rejects malformed ACL data, pagination loops, and a failed later page without partial results" do
    for response <- [
          %{
            "items" => [
              %{"id" => "missing-etag", "scope" => %{"type" => "user", "value" => "a@b.test"}}
            ]
          },
          %{
            "items" => [
              %{"id" => "bad-scope", "etag" => "etag", "scope" => %{"type" => "user"}}
            ]
          },
          %{"items" => [user_rule("one")], "nextPageToken" => "again"}
        ] do
      Req.Test.expect(Google, fn conn ->
        assert {"POST", "/token"} == {conn.method, conn.request_path}
        Req.Test.json(conn, %{"access_token" => "short-lived"})
      end)

      if response["nextPageToken"] do
        Req.Test.expect(Google, 2, fn conn ->
          assert {"GET", "/calendar/v3/calendars/training/acl"} ==
                   {conn.method, conn.request_path}

          list_json(conn, response)
        end)
      else
        Req.Test.expect(Google, fn conn ->
          assert {"GET", "/calendar/v3/calendars/training/acl"} ==
                   {conn.method, conn.request_path}

          list_json(conn, response)
        end)
      end

      assert {:error, :rejected} = Google.list("training")
    end

    Req.Test.expect(Google, 3, fn conn ->
      case {conn.request_path, conn.query_params} do
        {"/token", _params} ->
          Req.Test.json(conn, %{"access_token" => "short-lived"})

        {"/calendar/v3/calendars/training/acl", %{"pageToken" => "later"}} ->
          Plug.Conn.send_resp(conn, 500, "PRIVATE later-page provider body")

        {"/calendar/v3/calendars/training/acl", _params} ->
          list_json(conn, %{"items" => [user_rule("one")], "nextPageToken" => "later"})
      end
    end)

    assert {:error, :transient} = Google.list("training")
  end

  test "inserts only a reader user ACL and validates its returned rule" do
    Req.Test.expect(Google, 2, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/token"} ->
          Req.Test.json(conn, %{"access_token" => "short-lived"})

        {"POST", "/calendar/v3/calendars/training%40example.com/acl"} ->
          assert conn.query_params == %{"sendNotifications" => "true"}

          assert conn.body_params == %{
                   "role" => "reader",
                   "scope" => %{"type" => "user", "value" => "member@example.com"}
                 }

          Req.Test.json(conn, user_rule("rule-1", "member@example.com"))
      end
    end)

    assert {:ok, %{"id" => "rule-1"}} =
             Google.insert("training@example.com", "member@example.com")

    assert {:error, :rejected} = Google.insert("training", "")
  end

  test "uses If-Match and treats already deleted ACL rules as deleted" do
    for status <- [204, 404, 410] do
      Req.Test.expect(Google, 2, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/token"} ->
            Req.Test.json(conn, %{"access_token" => "short-lived"})

          {"DELETE", "/calendar/v3/calendars/training/acl/rule-1"} ->
            assert Plug.Conn.get_req_header(conn, "if-match") == ["etag-1"]
            Plug.Conn.send_resp(conn, status, "")
        end
      end)

      assert :ok = Google.delete("training", "rule-1", "etag-1")
    end
  end

  test "escapes rule IDs and maps an ETag conflict without exposing the response" do
    Req.Test.expect(Google, 2, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/token"} ->
          Req.Test.json(conn, %{"access_token" => "short-lived"})

        {"DELETE",
         "/calendar/v3/calendars/training%40example.com/acl/user%3Amember%2Btag%40example.com"} ->
          assert Plug.Conn.get_req_header(conn, "if-match") == ["etag-1"]
          Plug.Conn.send_resp(conn, 412, "PRIVATE conflict")
      end
    end)

    assert {:error, :conflict} =
             Google.delete("training@example.com", "user:member+tag@example.com", "etag-1")
  end

  test "malformed successful insert acknowledgments remain uncertain, not definite refusals" do
    Req.Test.expect(Google, 2, fn conn ->
      if conn.request_path == "/token",
        do: Req.Test.json(conn, %{"access_token" => "short-lived"}),
        else: Req.Test.json(conn, %{"id" => "created-without-acknowledgment"})
    end)

    assert {:error, :transient} = Google.insert("training", "person@example.com")
  end

  test "rejects a non-ACL successful listing or a rule without a known role" do
    for body <- [
          %{},
          %{"kind" => "calendar#events", "items" => []},
          %{"kind" => "calendar#acl", "items" => [Map.delete(user_rule("one"), "role")]},
          %{"kind" => "calendar#acl", "items" => [%{user_rule("one") | "etag" => " "}]}
        ] do
      Req.Test.expect(Google, 2, fn conn ->
        if conn.request_path == "/token",
          do: Req.Test.json(conn, %{"access_token" => "short-lived"}),
          else: Req.Test.json(conn, body)
      end)

      assert {:error, :rejected} = Google.list("training")
    end
  end

  test "a declared OAuth scope must be exactly ACL-only, never a broad or Workshop grant" do
    for scope <- [
          "https://www.googleapis.com/auth/calendar.events.owned",
          @scope <> " https://www.googleapis.com/auth/calendar",
          "https://www.googleapis.com/auth/calendar",
          []
        ] do
      Req.Test.expect(Google, fn conn ->
        assert conn.request_path == "/token"
        Req.Test.json(conn, %{"access_token" => "short-lived", "scope" => scope})
      end)

      assert {:error, :configuration} = Google.list("training")
    end
  end

  test "maps OAuth and Calendar failures to closed safe errors" do
    for {status, body, expected} <- [
          {401, %{}, :unauthorized},
          {404, %{}, :configuration},
          {409, %{}, :conflict},
          {410, %{}, :configuration},
          {429, %{}, :transient},
          {500, %{}, :transient},
          {403, %{"error" => %{"errors" => [%{"reason" => "rateLimitExceeded"}]}}, :transient},
          {403, %{}, :configuration}
        ] do
      Req.Test.stub(Google, fn conn ->
        if conn.request_path == "/token" do
          Req.Test.json(conn, %{"access_token" => "short-lived"})
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(status, Jason.encode!(body))
        end
      end)

      assert {:error, ^expected} = Google.list("training")
    end

    Req.Test.stub(Google, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{
        "error" => "invalid_grant",
        "error_description" => "PRIVATE provider error"
      })
    end)

    assert {:error, :unauthorized} = Google.list("training")

    Req.Test.stub(Google, fn conn ->
      Req.Test.json(conn, %{"access_token" => "short-lived", "scope" => "calendar.readonly"})
    end)

    assert {:error, :configuration} = Google.list("training")
  end

  test "does not log provider bodies or credentials" do
    Req.Test.stub(Google, fn conn ->
      if conn.request_path == "/token" do
        Req.Test.json(conn, %{"access_token" => "short-lived"})
      else
        Plug.Conn.send_resp(conn, 500, "PRIVATE provider response")
      end
    end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :transient} = Google.list("training")
      end)

    for forbidden <- ["training-secret", "training-refresh-token", "PRIVATE provider response"] do
      refute log =~ forbidden
    end
  end

  defp user_rule(id, email \\ "person@example.com"),
    do: %{
      "id" => id,
      "etag" => "etag-#{id}",
      "role" => "reader",
      "scope" => %{"type" => "user", "value" => email}
    }

  defp default_rule(id),
    do: %{"id" => id, "etag" => "etag-#{id}", "role" => "none", "scope" => %{"type" => "default"}}

  defp list_json(conn, body), do: Req.Test.json(conn, Map.put(body, "kind", "calendar#acl"))

  defp restore_config(nil), do: Application.delete_env(:dhc, Dhc.TrainingCalendar)
  defp restore_config(config), do: Application.put_env(:dhc, Dhc.TrainingCalendar, config)
end
