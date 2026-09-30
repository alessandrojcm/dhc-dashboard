defmodule DhcWeb.TrainingAnnouncementsControllerTest do
  use DhcWeb.ConnCase, async: false

  alias DhcWeb.OpenApiVerifier
  import DhcWeb.TrainingAnnouncementHTTPFixtures
  @roles ~w(sparring_coordinator coach president admin committee_coordinator)

  setup do
    original = install()
    on_exit(fn -> OpenApiVerifier.restore(original) end)
    :ok
  end

  test "only the five management roles can list announcements", %{conn: conn} do
    assert conn |> get("/api/training-announcements") |> json_response(401)
    assert conn |> as_role("member") |> get("/api/training-announcements") |> json_response(403)

    for role <- @roles do
      assert %{"data" => []} =
               conn |> as_role(role) |> get("/api/training-announcements") |> json_response(200)
    end
  end

  test "all management roles can create, edit, pause, resume, retire and delete", %{conn: conn} do
    for role <- @roles do
      authenticated = as_role(conn, role)
      body = attrs()

      assert %{
               "data" => %{
                 "announcement" => %{
                   "id" => id,
                   "kind" => "sparring",
                   "postTime" => "14:00:00",
                   "firstAttemptedAt" => nil
                 },
                 "warnings" => warnings
               }
             } = authenticated |> post("/api/training-announcements", body) |> json_response(201)

      assert warnings == []
      path = "/api/training-announcements/#{id}"
      assert %{"data" => %{"id" => ^id}} = authenticated |> get(path) |> json_response(200)

      assert %{
               "data" => %{
                 "announcement" => %{"postTime" => "15:00:00", "title" => "Training {{date}}"},
                 "warnings" => []
               }
             } =
               authenticated
               |> put(
                 path <> "/schedule",
                 Map.merge(body, %{"postTime" => "15:00:00", "title" => "Ignored"})
               )
               |> json_response(200)

      assert %{
               "data" => %{
                 "title" => "Changed",
                 "mentionEveryone" => true,
                 "postTime" => "15:00:00"
               }
             } =
               authenticated
               |> put(path <> "/copy", %{
                 "title" => "Changed",
                 "message" => "New copy",
                 "mentionEveryone" => true,
                 "postTime" => "01:00:00"
               })
               |> json_response(200)

      assert %{"data" => %{"enabled" => false}} =
               authenticated |> post(path <> "/disable") |> json_response(200)

      assert %{"data" => %{"enabled" => true}} =
               authenticated |> post(path <> "/enable") |> json_response(200)

      assert %{"data" => %{"retired" => true}} =
               authenticated |> post(path <> "/retire") |> json_response(200)

      assert %{"data" => []} =
               authenticated |> get("/api/training-announcements") |> json_response(200)

      assert %{"data" => [%{"id" => ^id}]} =
               authenticated
               |> get("/api/training-announcements?includeRetired=true")
               |> json_response(200)

      assert authenticated |> delete(path) |> response(204) == ""
      assert authenticated |> get(path) |> json_response(404)
    end
  end

  test "member and anonymous callers cannot reach any command or read", %{conn: conn} do
    id = Ecto.UUID.generate()

    for {method, path} <- [
          {:get, "/#{id}"},
          {:post, ""},
          {:post, "/preview-copy"},
          {:put, "/#{id}/schedule"},
          {:put, "/#{id}/copy"},
          {:post, "/#{id}/disable"},
          {:post, "/#{id}/enable"},
          {:post, "/#{id}/retire"},
          {:delete, "/#{id}"}
        ] do
      for {authenticated, status} <- [{conn, 401}, {as_role(conn, "member"), 403}] do
        assert authenticated
               |> request(method, "/api/training-announcements" <> path, attrs())
               |> json_response(status)
      end
    end
  end

  test "preview is stateless and renders the explicit mention for each role", %{conn: conn} do
    for role <- @roles do
      assert %{
               "data" => %{
                 "threadName" => "Training Thursday 5 September",
                 "renderedMessage" => "@everyone\nCome on Thursday"
               }
             } =
               conn
               |> as_role(role)
               |> post(
                 "/api/training-announcements/preview-copy",
                 Map.merge(attrs(), %{"date" => "2030-09-05", "mentionEveryone" => true})
               )
               |> json_response(200)
    end

    assert %{"data" => []} =
             conn |> as_role() |> get("/api/training-announcements") |> json_response(200)
  end

  test "validation errors are readable and expose public field names", %{conn: conn} do
    authenticated = as_role(conn)

    for body <- [
          Map.put(attrs(), "oneOffDate", "2020-01-01"),
          Map.put(attrs(), "message", "{{unknown}}"),
          Map.put(attrs(), "postTime", "bad")
        ] do
      assert %{"errors" => %{"detail" => detail, "fields" => fields}} =
               authenticated |> post("/api/training-announcements", body) |> json_response(422)

      assert detail != ""
      assert map_size(fields) > 0
    end

    assert %{"data" => %{"announcement" => %{"id" => id}}} =
             authenticated |> post("/api/training-announcements", attrs()) |> json_response(201)

    assert %{"errors" => %{"fields" => %{"postTime" => [message]}}} =
             authenticated
             |> put("/api/training-announcements/#{id}/schedule", %{
               "oneOffDate" => "2020-01-01",
               "postTime" => "14:00:00"
             })
             |> json_response(422)

    assert message =~ "elapsed"

    for body <- [
          %{"message" => "{{bad}}"},
          %{"title" => "{{date"},
          %{"message" => String.duplicate("x", 2001)},
          %{"title" => String.duplicate("x", 101)},
          %{"date" => "invalid"}
        ] do
      assert %{"errors" => %{"detail" => detail}} =
               authenticated
               |> post(
                 "/api/training-announcements/preview-copy",
                 attrs() |> Map.put("date", "2030-09-05") |> Map.merge(body)
               )
               |> json_response(422)

      assert detail != ""
    end

    assert authenticated
           |> get("/api/training-announcements?includeRetired=maybe")
           |> json_response(422)

    assert authenticated |> get("/api/training-announcements/bad-id") |> json_response(404)
  end

  test "attempted announcements must be retired instead of deleted", %{conn: conn} do
    authenticated = as_role(conn)

    %{"data" => %{"announcement" => %{"id" => id}}} =
      authenticated |> post("/api/training-announcements", attrs()) |> json_response(201)

    row = Dhc.Repo.get!(Dhc.TrainingAnnouncements.Announcement, id)
    row |> Ecto.Changeset.change(first_attempted_at: DateTime.utc_now()) |> Dhc.Repo.update!()
    path = "/api/training-announcements/#{id}"

    assert %{"errors" => %{"code" => "attempted", "detail" => detail}} =
             authenticated |> delete(path) |> json_response(409)

    assert detail =~ "retire"

    assert %{"errors" => %{"code" => "delivery_started"}} =
             authenticated
             |> put(path <> "/schedule", Map.take(attrs(), ["postTime", "oneOffDate"]))
             |> json_response(409)

    assert authenticated |> post(path <> "/retire") |> json_response(200)

    assert %{"errors" => %{"code" => "retired"}} =
             authenticated |> post(path <> "/enable") |> json_response(409)
  end

  test "schedule warnings expose the closed raw enums", %{conn: conn} do
    authenticated = as_role(conn)

    body =
      attrs()
      |> Map.delete("oneOffDate")
      |> Map.put("weekday", Date.day_of_week(Date.add(Dhc.ClubCalendar.today(), 1)))

    assert %{"data" => %{"announcement" => %{"id" => first}, "warnings" => []}} =
             authenticated |> post("/api/training-announcements", body) |> json_response(201)

    assert %{"data" => %{"announcement" => %{"id" => second}, "warnings" => ["slot_collision"]}} =
             authenticated |> post("/api/training-announcements", body) |> json_response(201)

    date = Date.to_iso8601(Date.add(Dhc.ClubCalendar.today(), 1))

    assert authenticated
           |> post("/api/training-announcements/#{first}/suppressions", %{
             "fromDate" => date,
             "toDate" => date
           })
           |> json_response(201)

    next_weekday = Integer.mod(body["weekday"], 7) + 1

    assert %{"data" => %{"warnings" => ["exception_intersection_changed"]}} =
             authenticated
             |> put("/api/training-announcements/#{first}/schedule", %{
               "weekday" => next_weekday,
               "postTime" => "14:00:00"
             })
             |> json_response(200)

    assert authenticated |> delete("/api/training-announcements/#{second}") |> response(204) == ""
  end

  test "kind is immutable and server-owned fields cannot be changed by callers", %{conn: conn} do
    authenticated = as_role(conn)

    %{"data" => %{"announcement" => %{"id" => id, "enabled" => true}}} =
      authenticated
      |> post(
        "/api/training-announcements",
        Map.merge(attrs(), %{
          "enabled" => false,
          "retired" => true,
          "firstAttemptedAt" => "2030-01-01T00:00:00Z"
        })
      )
      |> json_response(201)

    path = "/api/training-announcements/#{id}"

    for suffix <- ["/copy", "/schedule"] do
      assert %{"errors" => %{"fields" => %{"kind" => [_]}}} =
               authenticated
               |> put(path <> suffix, Map.put(attrs(), "kind", "roll_call"))
               |> json_response(422)
    end

    assert %{"data" => %{"enabled" => true, "retired" => false, "firstAttemptedAt" => nil}} =
             authenticated |> get(path) |> json_response(200)
  end

  test "out-of-range weekdays and null mention toggles return 422 rather than crash", %{
    conn: conn
  } do
    authenticated = as_role(conn)
    invalid_schedule = attrs() |> Map.delete("oneOffDate") |> Map.put("weekday", 8)

    assert %{"errors" => %{"fields" => %{"weekday" => [_]}}} =
             authenticated
             |> post("/api/training-announcements", invalid_schedule)
             |> json_response(422)

    assert authenticated
           |> post("/api/training-announcements", Map.put(attrs(), "mentionEveryone", nil))
           |> json_response(422)

    %{"data" => %{"announcement" => %{"id" => id}}} =
      authenticated |> post("/api/training-announcements", attrs()) |> json_response(201)

    path = "/api/training-announcements/#{id}"

    assert %{"errors" => %{"fields" => %{"weekday" => [_]}}} =
             authenticated
             |> put(path <> "/schedule", %{
               "weekday" => 8,
               "oneOffDate" => nil,
               "postTime" => "14:00:00"
             })
             |> json_response(422)

    assert authenticated
           |> put(path <> "/copy", %{"mentionEveryone" => nil})
           |> json_response(422)

    assert %{"data" => %{"mentionEveryone" => false}} =
             authenticated |> get(path) |> json_response(200)
  end

  defp request(conn, :get, path, _), do: get(conn, path)
  defp request(conn, :post, path, body), do: post(conn, path, body)
  defp request(conn, :put, path, body), do: put(conn, path, body)
  defp request(conn, :delete, path, _), do: delete(conn, path)
end
