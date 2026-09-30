defmodule DhcWeb.TrainingAnnouncementExceptionsControllerTest do
  use DhcWeb.ConnCase, async: false
  import DhcWeb.TrainingAnnouncementHTTPFixtures
  alias DhcWeb.OpenApiVerifier
  @roles ~w(sparring_coordinator coach president admin committee_coordinator)

  setup do
    original = install()
    on_exit(fn -> OpenApiVerifier.restore(original) end)
    :ok
  end

  test "all five roles can create, list and remove both exception kinds", %{conn: conn} do
    for role <- @roles do
      authenticated = as_role(conn, role)
      body = attrs()

      %{"data" => %{"announcement" => %{"id" => id}}} =
        authenticated |> post("/api/training-announcements", body) |> json_response(201)

      date = body["oneOffDate"]
      range = %{"fromDate" => date, "toDate" => date}

      for kind <- ["suppressions", "overrides"] do
        path = "/api/training-announcements/#{id}/#{kind}"

        request =
          if kind == "overrides", do: Map.put(range, "title", "Special session"), else: range

        assert %{
                 "data" => %{
                   "id" => exception_id,
                   "announcementId" => ^id,
                   "fromDate" => ^date,
                   "toDate" => ^date
                 }
               } = authenticated |> post(path, request) |> json_response(201)

        assert %{"data" => [%{"id" => ^exception_id}]} =
                 authenticated |> get(path) |> json_response(200)

        assert authenticated |> delete(path <> "/#{exception_id}") |> response(204) == ""
        assert %{"data" => []} = authenticated |> get(path) |> json_response(200)
      end
    end
  end

  test "no exception operation is available to members or anonymous callers", %{conn: conn} do
    for kind <- ["suppressions", "overrides"],
        {authenticated, status} <- [{conn, 401}, {as_role(conn, "member"), 403}] do
      path = "/api/training-announcements/#{Ecto.UUID.generate()}/#{kind}"
      assert authenticated |> get(path) |> json_response(status)
      assert authenticated |> post(path, %{}) |> json_response(status)
      assert authenticated |> delete(path <> "/#{Ecto.UUID.generate()}") |> json_response(status)
    end
  end

  test "overlap and dated-range errors arrive as readable 422 details", %{conn: conn} do
    authenticated = as_role(conn)
    body = attrs()

    %{"data" => %{"announcement" => %{"id" => id}}} =
      authenticated |> post("/api/training-announcements", body) |> json_response(201)

    path = "/api/training-announcements/#{id}"

    range = %{
      "fromDate" => body["oneOffDate"],
      "toDate" => body["oneOffDate"],
      "message" => "New message"
    }

    assert authenticated |> post(path <> "/overrides", range) |> json_response(201)

    assert %{"errors" => %{"detail" => detail}} =
             authenticated |> post(path <> "/overrides", range) |> json_response(422)

    assert detail =~ "overlap"

    for kind <- ["suppressions", "overrides"] do
      for invalid <- [
            %{"fromDate" => "2020-01-01", "toDate" => "2020-01-01", "title" => "Copy"},
            %{"fromDate" => "bad", "toDate" => body["oneOffDate"]},
            %{}
          ] do
        assert %{"errors" => %{"detail" => detail, "fields" => _}} =
                 authenticated |> post(path <> "/#{kind}", invalid) |> json_response(422)

        assert detail != ""
      end

      assert authenticated |> get("/api/training-announcements/bad/#{kind}") |> json_response(404)
      assert authenticated |> delete(path <> "/#{kind}/bad") |> json_response(404)
    end
  end

  test "an exception id cannot be removed through another announcement", %{conn: conn} do
    authenticated = as_role(conn)
    body = attrs()

    %{"data" => %{"announcement" => %{"id" => first}}} =
      authenticated |> post("/api/training-announcements", body) |> json_response(201)

    %{"data" => %{"announcement" => %{"id" => second}}} =
      authenticated |> post("/api/training-announcements", body) |> json_response(201)

    for kind <- ["suppressions", "overrides"] do
      range = %{
        "fromDate" => body["oneOffDate"],
        "toDate" => body["oneOffDate"],
        "title" => "Special"
      }

      %{"data" => %{"id" => exception_id}} =
        authenticated
        |> post("/api/training-announcements/#{first}/#{kind}", range)
        |> json_response(201)

      assert authenticated
             |> delete("/api/training-announcements/#{second}/#{kind}/#{exception_id}")
             |> json_response(404)

      assert %{"data" => [%{"id" => ^exception_id}]} =
               authenticated
               |> get("/api/training-announcements/#{first}/#{kind}")
               |> json_response(200)
    end
  end
end
