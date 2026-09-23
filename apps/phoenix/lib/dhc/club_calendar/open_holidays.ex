defmodule Dhc.ClubCalendar.OpenHolidays do
  @moduledoc """
  Minimal OpenHolidays API client for the Irish bank-holiday cache (ALE-319).

  One operation: `fetch_year/1` asks for Ireland (`countryIsoCode=IE`,
  English names) over the full calendar year — the bot's per-year request —
  and returns one row per holiday date. Multi-day holidays expand to one row
  per date in their inclusive range; every row carries the source holiday id
  so a renamed holiday upserts onto the same date.

  The base URL is `Application.get_env(:dhc, :openholidays_api_url)` with the
  public default `https://openholidaysapi.org`; tests point it at a Bypass
  stub. Responses are validated strictly: a non-list body or an item missing
  its id, dates, or names is `{:error, {:unexpected_shape, _}}`, never a
  partial cache write — the caller fails open and reports to Sentry.
  """

  @default_base_url "https://openholidaysapi.org"

  @doc """
  Fetches every Irish public holiday date for `year`.

  Returns `{:ok, rows}` where each row is `%{date: Date.t(), name: String.t(),
  source_id: String.t()}` (no `fetched_at`; the caller stamps the write), or
  `{:error, reason}` for transport failures, non-200 statuses, and
  unexpected body shapes.
  """
  @spec fetch_year(integer()) ::
          {:ok, [%{date: Date.t(), name: String.t(), source_id: String.t()}]}
          | {:error, term()}
  def fetch_year(year) when is_integer(year) and year > 0 do
    url = "#{base_url()}/PublicHolidays"

    params = [
      countryIsoCode: "IE",
      languageIsoCode: "EN",
      validFrom: "#{year}-01-01",
      validTo: "#{year}-12-31"
    ]

    case Req.get(url, params: params, retry: false, receive_timeout: 10_000) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        with {:ok, decoded} <- decode_body(body), do: parse(year, decoded)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body_summary(body)}}

      {:error, %Req.TransportError{} = error} ->
        {:error, {:transport, error.reason}}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc "The configured OpenHolidays base URL (public default when unset)."
  @spec base_url() :: String.t()
  def base_url do
    :dhc
    |> Application.get_env(:openholidays_api_url, @default_base_url)
    |> to_string()
    |> String.trim_trailing("/")
  end

  # The wire content type is not trustworthy (the API documents
  # `accept: text/json`, stubs may send none at all), so the body is
  # decoded explicitly instead of relying on Req's content-type sniffing.
  defp decode_body(body) when is_list(body), do: {:ok, body}

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, {:unexpected_shape, %{body: body_summary(body)}}}
    end
  end

  defp decode_body(body), do: {:error, {:unexpected_shape, %{body: body_summary(body)}}}

  defp parse(year, body) when is_list(body) do
    body
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, rows} ->
      case parse_item(item) do
        # Append in order (years hold a handful of holidays): the returned
        # rows run date-ascending within each multi-day holiday.
        {:ok, item_rows} ->
          {:cont, {:ok, rows ++ item_rows}}

        {:error, reason} ->
          {:halt, {:error, {:unexpected_shape, %{year: year, index: index, reason: reason}}}}
      end
    end)
  end

  defp parse(_year, body), do: {:error, {:unexpected_shape, %{body: body_summary(body)}}}

  defp parse_item(%{
         "id" => id,
         "startDate" => start_date,
         "endDate" => end_date,
         "name" => names
       })
       when is_binary(id) and is_binary(start_date) and is_binary(end_date) and is_list(names) do
    with {:ok, first} <- Date.from_iso8601(start_date),
         {:ok, last} <- Date.from_iso8601(end_date),
         name when is_binary(name) <- pick_name(names),
         :ok <- validate_range(first, last) do
      rows =
        Enum.map(Date.range(first, last), fn date ->
          %{date: date, name: name, source_id: id}
        end)

      {:ok, rows}
    else
      _ -> {:error, :invalid_item}
    end
  end

  defp parse_item(_), do: {:error, :invalid_item}

  defp validate_range(first, last) do
    if Date.compare(first, last) in [:lt, :eq], do: :ok, else: {:error, :invalid_range}
  end

  defp pick_name(names) do
    texts =
      for %{"text" => text} = entry <- names,
          is_binary(text),
          String.trim(text) != "",
          do: {Map.get(entry, "language"), text}

    case Enum.find(texts, fn {language, _text} -> language == "EN" end) || List.first(texts) do
      {_language, text} -> text
      nil -> nil
    end
  end

  defp body_summary(body) when is_binary(body), do: String.slice(body, 0, 500)
  defp body_summary(body), do: body |> inspect() |> String.slice(0, 500)
end
