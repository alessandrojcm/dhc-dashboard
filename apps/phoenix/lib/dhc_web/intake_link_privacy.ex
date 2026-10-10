defmodule DhcWeb.IntakeLinkPrivacy do
  @moduledoc """
  Keeps Intake link tokens out of logs and Sentry (ALE-381; ALE-374 story
  52). The token travels in the URL path (`/beginners/intake/<token>` on the
  page, `/api/beginners/intake/<token>` here), so every place that records a
  path or URL redacts that segment:

    * Phoenix's request log line — `log_level/1` is the endpoint's
      `Plug.Telemetry` log option and turns Phoenix's own line off for these
      paths; `DhcWeb.Plugs.IntakeLinkPage` logs a redacted line instead
      (router "Parameters" lines already filter the `token` param);
    * Sentry request context — `scrub_url/1` is `Sentry.PlugContext`'s
      `:url_scrubber`;
    * Sentry events and transactions (spans carry `url.path`) —
      `before_send/1` is Sentry's `:before_send` and redacts every string.
  """

  @segment ~r{(beginners/intake/)[^/?#\s"']+}
  @redacted "[REDACTED]"

  @doc "Replaces every Intake link token in `text`."
  @spec redact(String.t()) :: String.t()
  def redact(text) when is_binary(text), do: Regex.replace(@segment, text, "\\1#{@redacted}")

  @doc "Whether a request path is an Intake link path."
  @spec intake_path?(String.t()) :: boolean()
  def intake_path?(path) when is_binary(path), do: Regex.match?(@segment, path)

  @doc "`Plug.Telemetry` log level: Phoenix's request line is off for Intake link paths."
  @spec log_level(Plug.Conn.t()) :: false | :info
  def log_level(%Plug.Conn{request_path: path}),
    do: if(intake_path?(path), do: false, else: :info)

  @doc "`Sentry.PlugContext` URL scrubber: the default scrubber, then the token."
  @spec scrub_url(Plug.Conn.t()) :: String.t()
  def scrub_url(%Plug.Conn{} = conn),
    do: conn |> Sentry.PlugContext.default_url_scrubber() |> redact()

  @doc "Sentry `:before_send`: redacts every string of an event or transaction."
  @spec before_send(struct()) :: struct()
  def before_send(event), do: deep_redact(event)

  defp deep_redact(value) when is_binary(value), do: redact(value)
  defp deep_redact(list) when is_list(list), do: Enum.map(list, &deep_redact/1)

  defp deep_redact(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> deep_redact() |> List.to_tuple()

  defp deep_redact(%DateTime{} = value), do: value
  defp deep_redact(%NaiveDateTime{} = value), do: value
  defp deep_redact(%Date{} = value), do: value
  defp deep_redact(%Time{} = value), do: value

  defp deep_redact(%module{} = struct) do
    fields = struct |> Map.from_struct() |> deep_redact()
    struct(module, fields)
  end

  defp deep_redact(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {deep_redact(key), deep_redact(value)} end)

  defp deep_redact(other), do: other
end
