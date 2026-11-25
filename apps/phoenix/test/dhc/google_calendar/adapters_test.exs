defmodule Dhc.GoogleCalendar.AdaptersTest do
  use ExUnit.Case, async: false

  setup do
    Dhc.GoogleCalendarAuthConfig.configure!(__MODULE__)
  end

  test "both adapters use the shared connection, without feature-specific credentials" do
    Req.Test.expect(__MODULE__, 2, fn conn ->
      assert conn.host == "oauth2.googleapis.com"
      assert conn.body_params["client_id"] == "organizer-client"
      Req.Test.json(conn, Dhc.GoogleCalendarAuthConfig.token("shared-access"))
    end)

    Req.Test.expect(Dhc.WorkshopCalendar.Google, fn conn ->
      assert conn.method == "GET"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer shared-access"]
      Req.Test.json(conn, %{"kind" => "calendar#events"})
    end)

    Req.Test.expect(Dhc.TrainingCalendar.Google, fn conn ->
      assert conn.method == "GET"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer shared-access"]
      Req.Test.json(conn, %{"kind" => "calendar#acl", "items" => []})
    end)

    assert :ok = Dhc.WorkshopCalendar.Google.check_calendar("committee")
    assert {:ok, []} = Dhc.TrainingCalendar.Google.list("training")
  end
end
