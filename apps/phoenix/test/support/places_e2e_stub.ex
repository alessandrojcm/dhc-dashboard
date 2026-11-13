defmodule Dhc.PlacesE2EStub do
  @moduledoc """
  The synthetic Google Places answers the E2E server gives `Dhc.Places`
  (ALE-442), so Playwright exercises venue search and selection through the
  real Phoenix boundary without reaching Google. `config/test.exs` mounts it
  as the Places Req plug only when `E2E_SERVER=true`.

  Every place is fictional and every answer carries only the fields the
  boundary masks for; no provider response was recorded. A search containing
  `quota` answers 429 and one matching nothing answers no suggestions.
  """

  @behaviour Plug

  import Plug.Conn

  @places [
    %{
      "id" => "e2e_place_hall",
      "displayName" => %{"text" => "Synthetic Fencing Hall"},
      "formattedAddress" => "1 Example Street, Dublin 8, Ireland",
      "attributions" => [
        %{"provider" => "Example Venue Guide", "providerUri" => "https://venues.example.test/"}
      ]
    },
    %{
      "id" => "e2e_place_annex",
      "displayName" => %{"text" => "Synthetic Fencing Annex"},
      "formattedAddress" => "2 Example Street, Dublin 8, Ireland"
    }
  ]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "POST", request_path: "/v1/places:autocomplete"} = conn, _opts) do
    {:ok, body, conn} = read_body(conn)
    input = body |> Jason.decode!() |> Map.get("input", "") |> String.downcase()

    if String.contains?(input, "quota") do
      json(conn, 429, %{"error" => %{"status" => "RESOURCE_EXHAUSTED"}})
    else
      suggestions =
        for place <- @places,
            input != "" and String.contains?(String.downcase(label(place)), input),
            do: %{
              "placePrediction" => %{
                "placeId" => place["id"],
                "text" => %{"text" => label(place)}
              }
            }

      json(conn, 200, if(suggestions == [], do: %{}, else: %{"suggestions" => suggestions}))
    end
  end

  def call(%Plug.Conn{method: "GET", path_info: ["v1", "places", id]} = conn, _opts) do
    case Enum.find(@places, &(&1["id"] == id)) do
      nil -> json(conn, 404, %{"error" => %{"status" => "NOT_FOUND"}})
      place -> json(conn, 200, place)
    end
  end

  def call(conn, _opts), do: json(conn, 404, %{"error" => %{"status" => "NOT_FOUND"}})

  defp label(place), do: "#{place["displayName"]["text"]}, #{place["formattedAddress"]}"

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
