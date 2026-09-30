defmodule DhcWeb.TrainingAnnouncementOccurrencesControllerTest do
  use DhcWeb.ConnCase, async: false
  import DhcWeb.TrainingAnnouncementHTTPFixtures
  alias DhcWeb.OpenApiVerifier

  setup do
    original = install()
    on_exit(fn -> OpenApiVerifier.restore(original) end)
    :ok
  end

  test "window, occurrence detail and rail expose the same full projection", %{conn: conn} do
    conn = as_role(conn)

    %{"data" => %{"announcement" => %{"id" => id}}} =
      conn |> post("/api/training-announcements", attrs()) |> json_response(201)

    date = attrs()["oneOffDate"]

    assert %{"data" => [item]} =
             conn
             |> get("/api/training-announcements/occurrences/window", %{from: date, to: date})
             |> json_response(200)

    assert item["subject"] == "occurrence"
    assert item["announcementId"] == id
    assert item["chain"] == ["disablement", "suppression", "override", "defaults"]
    assert item["delivery"] == nil
    assert item["renderedMessage"] != nil

    assert %{"data" => ^item} =
             conn
             |> get("/api/training-announcements/#{id}/occurrences/#{date}")
             |> json_response(200)

    assert %{"data" => [^item]} =
             conn
             |> get("/api/training-announcements/#{id}/occurrences", %{
               direction: "upcoming",
               limit: 1
             })
             |> json_response(200)

    assert %{"data" => []} =
             conn
             |> get("/api/training-announcements/#{id}/occurrences", %{
               direction: "recent",
               limit: 1
             })
             |> json_response(200)
  end

  test "every occurrence read shares the committee-only authorization policy", %{conn: conn} do
    id = Ecto.UUID.generate()
    today = Date.to_iso8601(Dhc.ClubCalendar.today())

    for path <- [
          "/occurrences/window?from=#{today}&to=#{today}",
          "/#{id}/occurrences",
          "/#{id}/occurrences/#{today}"
        ] do
      assert conn |> get("/api/training-announcements" <> path) |> json_response(401)

      assert conn
             |> as_role("member")
             |> get("/api/training-announcements" <> path)
             |> json_response(403)
    end

    for role <- ~w(sparring_coordinator coach president admin committee_coordinator) do
      assert conn
             |> as_role(role)
             |> get("/api/training-announcements/occurrences/window", %{from: today, to: today})
             |> json_response(200)
    end
  end

  test "window bounds, date and rail validation return 422; absent slots return 404", %{
    conn: conn
  } do
    conn = as_role(conn)
    today = Dhc.ClubCalendar.today()
    horizon = Dhc.TrainingAnnouncements.retention_horizon()

    for params <- [
          %{},
          %{from: "bad", to: "bad"},
          %{from: Date.add(horizon, -1), to: horizon},
          %{from: today, to: Date.add(today, 62)},
          %{from: today, to: Date.add(today, -1)}
        ] do
      assert conn
             |> get("/api/training-announcements/occurrences/window", params)
             |> json_response(422)
    end

    assert %{"data" => []} =
             conn
             |> get("/api/training-announcements/occurrences/window", %{
               from: horizon,
               to: horizon
             })
             |> json_response(200)

    assert conn
           |> get("/api/training-announcements/occurrences/window", %{
             from: today,
             to: Date.add(today, 61)
           })
           |> json_response(200)

    %{"data" => %{"announcement" => %{"id" => id}}} =
      conn |> post("/api/training-announcements", attrs()) |> json_response(201)

    path = "/api/training-announcements/#{id}/occurrences"
    assert conn |> get(path <> "/#{today}") |> json_response(404)
    assert conn |> get(path <> "/bad") |> json_response(422)
    assert conn |> get("/api/training-announcements/bad-id/occurrences") |> json_response(404)

    for params <- [%{direction: "sideways"}, %{limit: 0}, %{limit: 51}, %{limit: "x"}] do
      assert conn |> get(path, params) |> json_response(422)
    end
  end

  test "past occurrence and holiday rows carry the full inspector evidence without current copy",
       %{conn: conn} do
    alias Dhc.Repo
    alias Dhc.TrainingAnnouncements.DiscordAnnouncementDelivery, as: Evidence
    conn = as_role(conn)

    %{"data" => %{"announcement" => %{"id" => id}}} =
      conn |> post("/api/training-announcements", attrs()) |> json_response(201)

    yesterday = Date.add(Dhc.ClubCalendar.today(), -1)
    now = DateTime.utc_now()

    Repo.insert!(%Evidence{
      subject: "occurrence",
      announcement_id: id,
      occurrence_date: yesterday,
      state: "thread_failed",
      reason: "timeout",
      resolved_outcome: "post_override",
      precedence_chain: ["disablement", "suppression", "override"],
      title_source: "Historic title",
      message_source: "Historic message",
      rendered_message: "Historic message",
      thread_name: "Historic title",
      channel_id: "123456789012345678",
      discord_message_id: "234567890123456789",
      frozen_at: now,
      posting_started_at: now,
      message_posted_at: now,
      concluded_at: now,
      thread_attempts: 3,
      error_detail: "Thread timeout",
      last_thread_error: "Thread timeout"
    })

    Repo.insert!(%Evidence{
      subject: "holiday",
      holiday_date: Dhc.ClubCalendar.today(),
      phase: "day_before",
      state: "delivered",
      resolved_outcome: "post",
      precedence_chain: ["holiday"],
      rendered_message: "Historic holiday",
      mention_everyone: true,
      concluded_at: now
    })

    assert %{"data" => items} =
             conn
             |> get("/api/training-announcements/occurrences/window", %{
               from: yesterday,
               to: yesterday
             })
             |> json_response(200)

    assert [_, _] = items
    item = Enum.find(items, &(&1["subject"] == "occurrence"))
    assert item["threadName"] == "Historic title"
    assert item["decidedBy"] == "override"
    assert item["delivery"]["threadAttempts"] == 3
    assert item["delivery"]["errorDetail"] == "Thread timeout"
    assert item["delivery"]["messagePostedAt"] != nil
    assert item["delivery"]["threadCreatedAt"] == nil
    holiday = Enum.find(items, &(&1["subject"] == "holiday"))
    assert holiday["readOnly"] == true
    assert holiday["date"] == Date.to_iso8601(yesterday)
    assert holiday["delivery"]["state"] == "delivered"

    assert %{"data" => ^item} =
             conn
             |> get("/api/training-announcements/#{id}/occurrences/#{yesterday}")
             |> json_response(200)

    assert %{"data" => [^item]} =
             conn
             |> get("/api/training-announcements/#{id}/occurrences", %{
               direction: "recent",
               limit: 1
             })
             |> json_response(200)
  end

  test "future holiday items use the same inspector contract", %{conn: conn} do
    date = Date.add(Dhc.ClubCalendar.today(), 7)

    Dhc.Repo.insert!(%Dhc.ClubCalendar.Holiday{
      date: date,
      name: "Bank holiday",
      source_id: "future",
      fetched_at: DateTime.utc_now()
    })

    conn = as_role(conn)

    conn
    |> post("/api/training-announcements", Map.put(attrs(), "kind", "roll_call"))
    |> json_response(201)

    assert %{"data" => items} =
             conn
             |> get("/api/training-announcements/occurrences/window", %{
               from: Date.add(date, -1),
               to: date
             })
             |> json_response(200)

    assert [_, _, _] = items

    for item <- Enum.filter(items, & &1["readOnly"]) do
      assert item["delivery"] == nil
      assert item["chain"] == ["holiday"]
      assert item["renderedMessage"] =~ "Bank holiday"
    end
  end
end
