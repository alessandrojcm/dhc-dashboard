defmodule DhcWeb.VenueLookupControllerTest do
  @moduledoc """
  ALE-442: the venue lookup HTTP slice — capability-gated, uncached, closed
  bodies, and closed failures that leave manual entry available. Google is
  substituted at the one `Dhc.Places` Req boundary.
  """

  # Not async: one test removes the shared Places key.
  use DhcWeb.ConnCase, async: false

  alias Dhc.Auth.Principal
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias DhcWeb.OpenApiVerifier

  @actor "44444444-4444-4444-4444-444444444444"
  @session "6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b"

  setup do
    original =
      OpenApiVerifier.install(
        actor_id: @actor,
        roles:
          ~w(workshop_coordinator beginners_coordinator president admin committee_coordinator member coach treasurer)
      )

    {:ok, _} =
      %Principal{id: @actor}
      |> Principal.email_changeset(%{email: "venue-lookup@example.com"})
      |> Repo.insert()

    {:ok, _} =
      Repo.insert(%UserProfile{
        principal_id: @actor,
        first_name: "Venue",
        last_name: "Coordinator",
        phone_number: "+353810000000",
        date_of_birth: ~D[1990-01-01],
        gender: "man (cis)",
        pronouns: "he/him",
        is_active: true,
        social_media_consent: "no"
      })

    on_exit(fn -> OpenApiVerifier.restore(original) end)
    :ok
  end

  defp auth(role), do: put_req_header(build_conn(), "authorization", "Bearer #{role}-token")

  defp google(status, body) do
    Req.Test.stub(Dhc.Places, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end)
  end

  defp suggest(role, input),
    do: post(auth(role), "/api/venue-lookup/suggestions", %{input: input, sessionToken: @session})

  defp resolve(role, place_id),
    do:
      post(auth(role), "/api/venue-lookup/selections", %{
        placeId: place_id,
        sessionToken: @session
      })

  test "both Workshop schedulers may search, with uncached ordered suggestions" do
    google(200, %{
      "suggestions" => [
        %{
          "placePrediction" => %{"placeId" => "place_hall", "text" => %{"text" => "Hall, Dublin"}}
        }
      ]
    })

    for role <- ~w(workshop_coordinator beginners_coordinator) do
      conn = suggest(role, "hall")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "suggestions" => [%{"placeId" => "place_hall", "text" => "Hall, Dublin"}]
               }
             }

      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end

  test "a selection is a closed preview with its credits" do
    google(200, %{
      "id" => "place_hall",
      "displayName" => %{"text" => "Synthetic Fencing Hall"},
      "formattedAddress" => "1 Example Street, Dublin 8",
      "attributions" => [%{"provider" => "Venue Guide", "providerUri" => "https://guide.test/"}],
      "rating" => 5
    })

    conn = resolve("beginners_coordinator", "place_hall")

    assert json_response(conn, 200) == %{
             "data" => %{
               "provider" => "google",
               "placeId" => "place_hall",
               "name" => "Synthetic Fencing Hall",
               "address" => "1 Example Street, Dublin 8",
               "attributions" => [
                 %{"provider" => "Venue Guide", "providerUri" => "https://guide.test/"}
               ]
             }
           }

    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "people who schedule no workshop cannot search" do
    Req.Test.stub(Dhc.Places, fn _conn -> flunk("Google must not be called") end)

    for role <- ~w(member coach treasurer) do
      assert %{"errors" => %{"detail" => _}} = json_response(suggest(role, "hall"), 403)
    end

    assert json_response(
             post(build_conn(), "/api/venue-lookup/suggestions", %{
               input: "hall",
               sessionToken: @session
             }),
             401
           )
  end

  test "no match, quota, authorization and outages answer closed problems" do
    google(200, %{})
    assert json_response(suggest("admin", "nowhere"), 200) == %{"data" => %{"suggestions" => []}}

    google(429, %{"error" => %{"message" => "provider secret detail"}})
    body = json_response(suggest("admin", "hall"), 503)
    assert body["errors"]["detail"] =~ "reached its limit"
    refute inspect(body) =~ "provider secret detail"

    google(403, %{"error" => %{"status" => "PERMISSION_DENIED"}})
    assert json_response(suggest("admin", "hall"), 502)["errors"]["detail"] =~ "isn't authorised"

    google(500, %{})
    assert json_response(suggest("admin", "hall"), 502)["errors"]["detail"] =~ "unavailable"

    google(404, %{})
    assert json_response(resolve("admin", "place_gone"), 404)["errors"]["detail"] =~ "no longer"

    assert %{"errors" => %{"code" => "invalid_query"}} = json_response(suggest("admin", ""), 422)
  end

  test "unconfigured Google says so and enters nothing" do
    previous = Application.get_env(:dhc, :places_api_key)
    Application.delete_env(:dhc, :places_api_key)
    on_exit(fn -> Application.put_env(:dhc, :places_api_key, previous) end)

    assert json_response(suggest("admin", "hall"), 503)["errors"]["detail"] =~ "isn't set up"
  end
end
