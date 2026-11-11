defmodule Dhc.Places do
  @moduledoc """
  The one domain-neutral Google Places lookup boundary (ALE-442), over Req.

  It searches for venues and resolves a deliberately chosen suggestion into a
  closed preview, following the ALE-439 contract
  (`docs/google-places-terms-validation.md`): Autocomplete (New), then Place
  Details (New) on selection. It has **no source-write authority** — it never
  reads or writes a workshop — and each Workshop domain saves a selection
  through its own commands. Only the Place ID of a selection is ever saved
  (`Dhc.Destinations` owns that rule); the name, address and credits below
  are a transient editing preview, never stored, shown to attendees or sent
  to Calendar.

    * `suggest/2` — `POST /v1/places:autocomplete` with `input`, the
      caller's session token, `languageCode: en`, `regionCode: ie` and a
      30 km circle **bias** on Dublin (other places are still returned:
      no restriction, type filter, origin or query predictions). Answers the
      ordered `%{place_id, text}` suggestions; none is an empty success.
    * `resolve/2` — `GET /v1/places/{id}` with the same session token and
      `languageCode=en`, masked to `id,displayName,formattedAddress,
      attributions`. Answers `%{provider: "google", place_id, name, address,
      attributions}`; `displayName.text` is the name and credits are
      `%{"provider", "provider_uri"}`.

  Google receives only the venue query or Place ID, the random session
  token, the fixed bias and language, the field mask and the server key —
  never cookies, client IPs, a Referer, workshop facts or attendee data.
  Errors are the closed `t:error/0` atoms, so no query, key or provider body
  can reach a log or Sentry through an error term. Nothing is cached.

  Configuration is optional: with no `:places_api_key` every call answers
  `{:error, :not_configured}` and manual destinations keep working. The key
  is server-only (`GOOGLE_PLACES_API_KEY`), restricted to Places API (New)
  and the deployment's egress IPs; it is separate from Calendar OAuth.

  Tests stub Google with `Req.Test.stub(Dhc.Places, plug)`; `config/test.exs`
  sets `:places_req_options` to `plug: {Req.Test, Dhc.Places}`.
  """

  alias Dhc.Destinations

  @autocomplete_mask "suggestions.placePrediction.placeId,suggestions.placePrediction.text.text"
  @details_mask "id,displayName,formattedAddress,attributions"

  # Dublin city centre; a bias, never a restriction.
  @dublin_bias %{
    circle: %{center: %{latitude: 53.3498, longitude: -6.2603}, radius: 30_000.0}
  }

  @input_max 120
  @attributions_max 10
  @provider_name_max 200
  @uuid_v4 ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i

  @type error ::
          :not_configured
          | :invalid_query
          | :invalid_session
          | :invalid_place
          | :not_found
          | :quota_exceeded
          | :unauthorized
          | :unavailable

  @type suggestion :: %{place_id: String.t(), text: String.t()}

  @type selection :: %{
          provider: String.t(),
          place_id: String.t(),
          name: String.t() | nil,
          address: String.t() | nil,
          attributions: [%{String.t() => String.t() | nil}]
        }

  @doc "The maximum length of a venue search."
  @spec input_max() :: pos_integer()
  def input_max, do: @input_max

  @doc "Venue suggestions for `input`, biased toward Dublin."
  @spec suggest(term(), term()) :: {:ok, [suggestion()]} | {:error, error()}
  def suggest(input, session_token) do
    with {:ok, input} <- valid_input(input),
         :ok <- valid_session(session_token),
         {:ok, body} <-
           request(:suggest, :post, "/v1/places:autocomplete", @autocomplete_mask,
             json: %{
               input: input,
               sessionToken: session_token,
               languageCode: "en",
               regionCode: "ie",
               locationBias: @dublin_bias
             }
           ) do
      suggestions(body)
    end
  end

  @doc "The closed preview of a chosen suggestion."
  @spec resolve(term(), term()) :: {:ok, selection()} | {:error, error()}
  def resolve(place_id, session_token) do
    with :ok <- valid_place(place_id),
         :ok <- valid_session(session_token),
         {:ok, body} <-
           request(:resolve, :get, "/v1/places/#{URI.encode(place_id)}", @details_mask,
             params: [sessionToken: session_token, languageCode: "en"]
           ) do
      selection(body)
    end
  end

  # ── Input bounds ─────────────────────────────────────────────────────

  defp valid_input(input) when is_binary(input) do
    case String.trim(input) do
      "" ->
        {:error, :invalid_query}

      trimmed ->
        if String.length(trimmed) <= @input_max,
          do: {:ok, trimmed},
          else: {:error, :invalid_query}
    end
  end

  defp valid_input(_input), do: {:error, :invalid_query}

  defp valid_session(token) when is_binary(token),
    do: if(Regex.match?(@uuid_v4, token), do: :ok, else: {:error, :invalid_session})

  defp valid_session(_token), do: {:error, :invalid_session}

  defp valid_place(place_id),
    do: if(Destinations.valid_place_id?(place_id), do: :ok, else: {:error, :invalid_place})

  # ── Transport ────────────────────────────────────────────────────────

  defp request(kind, method, path, mask, options) do
    case Application.get_env(:dhc, :places_api_key) do
      key when is_binary(key) and key != "" ->
        [
          method: method,
          base_url: Application.get_env(:dhc, :places_api_url, "https://places.googleapis.com"),
          url: path,
          headers: [{"x-goog-api-key", key}, {"x-goog-fieldmask", mask}],
          retry: false,
          receive_timeout: 5_000
        ]
        |> Keyword.merge(options)
        |> Keyword.merge(Application.get_env(:dhc, :places_req_options, []))
        |> Req.new()
        |> Req.request()
        |> response(kind)

      _unset ->
        {:error, :not_configured}
    end
  end

  defp response({:ok, %Req.Response{status: status, body: %{} = body}}, _kind)
       when status in 200..299,
       do: {:ok, body}

  defp response({:ok, %Req.Response{status: status}}, _kind) when status in 200..299,
    do: {:error, :unavailable}

  # Google reports a rejected key as a 400 naming `API_KEY_INVALID`.
  defp response({:ok, %Req.Response{status: 400, body: body}}, kind) do
    cond do
      invalid_key?(body) -> {:error, :unauthorized}
      kind == :resolve -> {:error, :not_found}
      true -> {:error, :unavailable}
    end
  end

  defp response({:ok, %Req.Response{status: 404}}, :resolve), do: {:error, :not_found}
  defp response({:ok, %Req.Response{status: 429}}, _kind), do: {:error, :quota_exceeded}

  defp response({:ok, %Req.Response{status: status}}, _kind) when status in [401, 403],
    do: {:error, :unauthorized}

  defp response({:ok, %Req.Response{}}, _kind), do: {:error, :unavailable}
  defp response({:error, _exception}, _kind), do: {:error, :unavailable}

  defp invalid_key?(%{"error" => %{"details" => details}}) when is_list(details),
    do: Enum.any?(details, &match?(%{"reason" => "API_KEY_INVALID"}, &1))

  defp invalid_key?(_body), do: false

  # ── Mapping (closed shapes only) ─────────────────────────────────────

  defp suggestions(%{"suggestions" => list}) when is_list(list) do
    suggestions =
      for %{"placePrediction" => %{"placeId" => id, "text" => %{"text" => text}}} <- list,
          Destinations.valid_place_id?(id),
          is_binary(text),
          do: %{place_id: id, text: text}

    {:ok, suggestions}
  end

  # No suggestions: Google omits the key.
  defp suggestions(%{}), do: {:ok, []}

  defp selection(%{"id" => id} = body) when is_binary(id) do
    name = get_in(body, ["displayName", "text"])
    address = body["formattedAddress"]

    with true <- Destinations.valid_place_id?(id),
         {:ok, attributions} <- attributions(Map.get(body, "attributions", [])) do
      {:ok,
       %{
         provider: "google",
         place_id: id,
         name: text(name, Destinations.name_max()),
         address: text(address, Destinations.address_max()),
         attributions: attributions
       }}
    else
      _invalid -> {:error, :unavailable}
    end
  end

  defp selection(_body), do: {:error, :unavailable}

  defp text(value, max) when is_binary(value) do
    case Destinations.normalize_optional(value) do
      nil -> nil
      trimmed -> String.slice(trimmed, 0, max)
    end
  end

  defp text(_value, _max), do: nil

  # Third-party credits as `%{"provider" => name, "provider_uri" => https | nil}`,
  # at most #{@attributions_max}; anything else makes the preview unusable.
  defp attributions(list) when is_list(list) and length(list) <= @attributions_max do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case attribution(item) do
        {:ok, credit} -> {:cont, {:ok, [credit | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp attributions(_other), do: :error

  defp attribution(%{} = item) do
    provider = text(item["provider"], @provider_name_max)

    uri =
      if is_binary(item["providerUri"]), do: Destinations.normalize_optional(item["providerUri"])

    if is_binary(provider) and https_uri?(uri),
      do: {:ok, %{"provider" => provider, "provider_uri" => uri}},
      else: :error
  end

  defp attribution(_item), do: :error

  defp https_uri?(nil), do: true

  defp https_uri?(uri) do
    String.length(uri) <= Destinations.url_max() and
      match?(
        {:ok, %URI{scheme: "https", host: host, userinfo: nil}}
        when is_binary(host) and host != "",
        URI.new(uri)
      )
  end
end
