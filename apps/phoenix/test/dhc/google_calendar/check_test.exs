defmodule Dhc.GoogleCalendar.CheckTest do
  use ExUnit.Case, async: false

  alias Dhc.GoogleCalendar

  setup do
    Dhc.GoogleCalendarAuthConfig.configure!(__MODULE__)

    for {module, config} <- [
          {Dhc.WorkshopCalendar,
           [committee_calendar_id: "committee", participant_calendar_id: "participants"]},
          {Dhc.TrainingCalendar, [enabled: false, calendar_id: "training"]}
        ] do
      previous = Application.get_env(:dhc, module)
      existing = previous || []
      Application.put_env(:dhc, module, Keyword.merge(existing, config))
      on_exit(fn -> Application.put_env(:dhc, module, previous) end)
    end

    :ok
  end

  test "checks loaded credentials and each calendar with GET only, even while sending is disabled" do
    Req.Test.expect(__MODULE__, 4, fn conn ->
      assert conn.host == "oauth2.googleapis.com"
      Req.Test.json(conn, Dhc.GoogleCalendarAuthConfig.token("PRIVATE-token"))
    end)

    Req.Test.expect(Dhc.WorkshopCalendar.Google, 2, fn conn ->
      assert conn.method == "GET"
      assert conn.query_params == %{"maxResults" => "1", "fields" => "kind"}
      Req.Test.json(conn, %{"kind" => "calendar#events"})
    end)

    Req.Test.expect(Dhc.TrainingCalendar.Google, fn conn ->
      assert conn.method == "GET"
      Req.Test.json(conn, %{"kind" => "calendar#acl", "items" => []})
    end)

    assert GoogleCalendar.check() == %{
             authentication: :ok,
             calendars: %{committee: :ok, participants: :ok, training: :ok}
           }

    refute Application.fetch_env!(:dhc, Dhc.TrainingCalendar)[:enabled]
  end

  test "a rejected client reports the repairable cause without trying any calendar" do
    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"error" => "invalid_client", "error_description" => "PRIVATE"})
    end)

    assert GoogleCalendar.check() == %{authentication: :invalid_client, calendars: %{}}
  end

  test "reports an inaccessible target separately from authentication and continues other checks" do
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, Dhc.GoogleCalendarAuthConfig.token("access")))

    Req.Test.expect(Dhc.WorkshopCalendar.Google, 2, fn conn ->
      assert conn.method == "GET"

      if String.contains?(conn.request_path, "/committee/"),
        do: Plug.Conn.send_resp(conn, 404, ""),
        else: Req.Test.json(conn, %{"kind" => "calendar#events"})
    end)

    Req.Test.expect(Dhc.TrainingCalendar.Google, fn conn ->
      Req.Test.json(conn, %{"kind" => "calendar#acl", "items" => []})
    end)

    assert GoogleCalendar.check() == %{
             authentication: :ok,
             calendars: %{committee: :target_inaccessible, participants: :ok, training: :ok}
           }
  end

  test "missing target IDs never fall back to the organizer's primary calendar" do
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, Dhc.GoogleCalendarAuthConfig.token("access")))
    Application.put_env(:dhc, Dhc.WorkshopCalendar, [])
    Application.put_env(:dhc, Dhc.TrainingCalendar, calendar_id: "primary")

    assert GoogleCalendar.check() == %{
             authentication: :ok,
             calendars: %{
               committee: :configuration,
               participants: :configuration,
               training: :configuration
             }
           }
  end
end
