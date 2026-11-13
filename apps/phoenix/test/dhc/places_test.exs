defmodule Dhc.PlacesTest do
  @moduledoc """
  ALE-442: the Google Places lookup boundary's exact provider requests and
  closed mapping, through `Req.Test` with synthetic answers only (no live
  Google and no recorded provider response).
  """

  # Not async: one test removes the shared Places key.
  use ExUnit.Case, async: false

  alias Dhc.Places

  @session "6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b"

  defp stub(fun), do: Req.Test.stub(Dhc.Places, fun)

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  describe "suggest/2" do
    test "sends the venue query with a Dublin bias, never a restriction, and maps suggestions" do
      test_pid = self()

      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, conn, Jason.decode!(body)})

        json(conn, 200, %{
          "suggestions" => [
            %{"placePrediction" => %{"placeId" => "place_b", "text" => %{"text" => "Hall B"}}},
            %{"queryPrediction" => %{"text" => %{"text" => "ignored query"}}},
            %{"placePrediction" => %{"placeId" => "place_a", "text" => %{"text" => "Hall A"}}}
          ]
        })
      end)

      assert {:ok,
              [%{place_id: "place_b", text: "Hall B"}, %{place_id: "place_a", text: "Hall A"}]} =
               Places.suggest("  Synthetic hall  ", @session)

      assert_received {:request, conn, body}
      assert conn.method == "POST"
      assert conn.request_path == "/v1/places:autocomplete"
      assert Plug.Conn.get_req_header(conn, "x-goog-api-key") == ["places-test-key"]

      assert Plug.Conn.get_req_header(conn, "x-goog-fieldmask") == [
               "suggestions.placePrediction.placeId,suggestions.placePrediction.text.text"
             ]

      # Only venue search information reaches Google.
      assert Plug.Conn.get_req_header(conn, "cookie") == []
      assert Plug.Conn.get_req_header(conn, "referer") == []
      assert Plug.Conn.get_req_header(conn, "x-forwarded-for") == []

      assert body == %{
               "input" => "Synthetic hall",
               "sessionToken" => @session,
               "languageCode" => "en",
               "regionCode" => "ie",
               "locationBias" => %{
                 "circle" => %{
                   "center" => %{"latitude" => 53.3498, "longitude" => -6.2603},
                   "radius" => 30_000.0
                 }
               }
             }

      refute Map.has_key?(body, "locationRestriction")
      refute Map.has_key?(body, "includedPrimaryTypes")
    end

    test "no match is an empty success" do
      stub(&json(&1, 200, %{}))
      assert {:ok, []} = Places.suggest("nowhere", @session)
    end

    test "bounds the query and the session token before calling Google" do
      stub(fn _conn -> flunk("Google must not be called") end)

      assert {:error, :invalid_query} = Places.suggest("   ", @session)
      assert {:error, :invalid_query} = Places.suggest(String.duplicate("a", 121), @session)
      assert {:error, :invalid_query} = Places.suggest(nil, @session)
      assert {:error, :invalid_session} = Places.suggest("hall", "not-a-uuid")
      # A UUID v1 is not a fresh random session token.
      assert {:error, :invalid_session} =
               Places.suggest("hall", "6f1c2a3b-4d5e-1f60-8a7b-9c0d1e2f3a4b")
    end

    test "quota, authorization and outages are closed errors" do
      stub(&json(&1, 429, %{"error" => %{"status" => "RESOURCE_EXHAUSTED"}}))
      assert {:error, :quota_exceeded} = Places.suggest("hall", @session)

      stub(&json(&1, 403, %{"error" => %{"status" => "PERMISSION_DENIED"}}))
      assert {:error, :unauthorized} = Places.suggest("hall", @session)

      stub(
        &json(&1, 400, %{
          "error" => %{"details" => [%{"reason" => "API_KEY_INVALID"}], "message" => "bad key"}
        })
      )

      assert {:error, :unauthorized} = Places.suggest("hall", @session)

      stub(&json(&1, 400, %{"error" => %{"status" => "INVALID_ARGUMENT"}}))
      assert {:error, :unavailable} = Places.suggest("hall", @session)

      stub(&json(&1, 503, %{"error" => %{"status" => "UNAVAILABLE"}}))
      assert {:error, :unavailable} = Places.suggest("hall", @session)

      stub(&Req.Test.transport_error(&1, :timeout))
      assert {:error, :unavailable} = Places.suggest("hall", @session)
    end
  end

  describe "resolve/2" do
    test "asks for the closed field mask with the same session and maps the preview" do
      test_pid = self()

      stub(fn conn ->
        send(test_pid, {:request, conn})

        json(conn, 200, %{
          "id" => "place_hall",
          "displayName" => %{"text" => "Synthetic Fencing Hall", "languageCode" => "en"},
          "formattedAddress" => "1 Example Street, Dublin 8, Ireland",
          "attributions" => [
            %{"provider" => "Venue Guide", "providerUri" => "https://guide.example.test/"}
          ],
          "name" => "places/place_hall"
        })
      end)

      assert {:ok,
              %{
                provider: "google",
                place_id: "place_hall",
                name: "Synthetic Fencing Hall",
                address: "1 Example Street, Dublin 8, Ireland",
                attributions: [
                  %{"provider" => "Venue Guide", "provider_uri" => "https://guide.example.test/"}
                ]
              } = selection} = Places.resolve("place_hall", @session)

      assert map_size(selection) == 5

      assert_received {:request, conn}
      assert conn.method == "GET"
      assert conn.request_path == "/v1/places/place_hall"
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params == %{"sessionToken" => @session, "languageCode" => "en"}

      assert Plug.Conn.get_req_header(conn, "x-goog-fieldmask") == [
               "id,displayName,formattedAddress,attributions"
             ]
    end

    test "a place without credits has none" do
      stub(&json(&1, 200, %{"id" => "place_hall", "displayName" => %{"text" => "Hall"}}))

      assert {:ok, %{name: "Hall", address: nil, attributions: []}} =
               Places.resolve("place_hall", @session)
    end

    test "an obsolete place is not found and a malformed id never reaches Google" do
      stub(&json(&1, 404, %{"error" => %{"status" => "NOT_FOUND"}}))
      assert {:error, :not_found} = Places.resolve("place_gone", @session)

      stub(&json(&1, 400, %{"error" => %{"status" => "INVALID_ARGUMENT"}}))
      assert {:error, :not_found} = Places.resolve("place_gone", @session)

      assert {:error, :invalid_place} = Places.resolve("../v1/places:autocomplete", @session)
    end

    test "an unexpected provider body is refused rather than passed through" do
      stub(&json(&1, 200, %{"displayName" => %{"text" => "No id"}}))
      assert {:error, :unavailable} = Places.resolve("place_hall", @session)

      stub(
        &json(&1, 200, %{
          "id" => "place_hall",
          "attributions" => [%{"provider" => "X", "providerUri" => "http://insecure.test/"}]
        })
      )

      assert {:error, :unavailable} = Places.resolve("place_hall", @session)
    end
  end

  test "without a key every lookup is unconfigured and nothing is sent" do
    previous = Application.get_env(:dhc, :places_api_key)
    Application.delete_env(:dhc, :places_api_key)
    on_exit(fn -> Application.put_env(:dhc, :places_api_key, previous) end)

    stub(fn _conn -> flunk("Google must not be called") end)

    assert {:error, :not_configured} = Places.suggest("hall", @session)
    assert {:error, :not_configured} = Places.resolve("place_hall", @session)
  end
end
