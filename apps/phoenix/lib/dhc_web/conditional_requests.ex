defmodule DhcWeb.ConditionalRequests do
  @moduledoc """
  Conditional-request (RFC 9110) support for versioned resources — ADR 0023,
  Phase 1.2 (ALE-266).

  ETags are concurrency validators, not HTTP caching: the strong ETag is the
  quoted decimal `lock_version` of the entity (e.g. `"7"`). Collection
  conditional GETs are out of scope.

  Preconditions are opt-in: with no conditional headers, requests behave
  exactly as before. AEP-154 requires supporting all preconditions or none,
  so the *date-based* conditionals this API does not implement
  (`If-Modified-Since`, `If-Unmodified-Since`, `If-Range`) are rejected with
  `400` instead of being silently ignored.
  """

  import Plug.Conn

  @unsupported_if_headers ~w(if-modified-since if-unmodified-since if-range)

  @typedoc "Parsed If-Match instruction."
  @type if_match :: {:any_existing, :*} | {:version, pos_integer()}

  @typedoc "Outcome of evaluating conditional headers against an entity version."
  @type precondition ::
          {:ok, nil | if_match()}
          | {:not_modified, etag()}
          | {:precondition_failed}
          | {:error, :unsupported_header | :invalid_if_match}

  @type etag :: String.t()

  # ── ETag ──────────────────────────────────────────────────────────────

  @doc """
  Strong ETag for an entity's `lock_version`, e.g. `"1"` (quoted, per the
  RFC 9110 entity-tag format).
  """
  @spec etag(pos_integer()) :: etag()
  def etag(lock_version) when is_integer(lock_version) and lock_version >= 1 do
    ~s("#{lock_version}")
  end

  @doc """
  Attach the entity's strong ETag to the response as the `ETag` header.
  """
  @spec put_etag(Plug.Conn.t(), pos_integer()) :: Plug.Conn.t()
  def put_etag(conn, lock_version) do
    put_resp_header(conn, "etag", etag(lock_version))
  end

  # ── Precondition evaluation ───────────────────────────────────────────

  @doc """
  Evaluate the request's conditional headers against `lock_version`.

  Returns:

    * `{:ok, nil}` — no conditional headers present; behave as before.
    * `{:ok, {:any_existing, :*} | {:version, n}}` — an If-Match to enforce
      before the write (see `enforce_if_match/2`).
    * `{:not_modified, etag}` — GET's If-None-Match matches; send 304.
    * `{:precondition_failed}` — GET's If-None-Match demanded `*` (or a
      version) that the current entity does not satisfy.
    * `{:error, :unsupported_header | :invalid_if_match}` — reject with 400
      (AEP-154 / malformed header).
  """
  @spec evaluate(Plug.Conn.t(), pos_integer()) :: precondition()
  def evaluate(conn, lock_version) do
    with :ok <- reject_unsupported(conn) do
      cond do
        header_present?(conn, "if-match") ->
          conn |> header("if-match") |> parse_if_match_tag()

        header_present?(conn, "if-none-match") ->
          conn |> header("if-none-match") |> evaluate_if_none_match(lock_version)

        true ->
          {:ok, nil}
      end
    end
  end

  @doc """
  Parse the write-side precondition (`If-Match`) for PATCH/DELETE-style
  endpoints.

  Returns `{:ok, nil}` (no If-Match — behave as before), `{:ok, if_match}`,
  or `{:error, reason}` for malformed or unsupported conditional headers.
  `If-None-Match` is ignored on writes (RFC 9110: it is a GET/HEAD
  validator), but unsupported date-based conditionals still 400.
  """
  @spec parse_if_match(Plug.Conn.t()) ::
          {:ok, nil | if_match()} | {:error, :unsupported_header | :invalid_if_match}
  def parse_if_match(conn) do
    with :ok <- reject_unsupported(conn) do
      if header_present?(conn, "if-match") do
        conn |> header("if-match") |> parse_if_match_tag()
      else
        {:ok, nil}
      end
    end
  end

  @doc """
  Convert write-side conditional headers into context options.

  An absent `If-Match` keeps the write unconditional. A concrete entity tag
  becomes an expected lock version, while `*` records that any existing
  entity satisfies the precondition.
  """
  @spec write_options(Plug.Conn.t()) ::
          {:ok, keyword()} | {:error, :unsupported_header | :invalid_if_match}
  def write_options(conn) do
    case parse_if_match(conn) do
      {:ok, nil} -> {:ok, []}
      {:ok, {:version, version}} -> {:ok, expected_lock_version: version}
      {:ok, {:any_existing, :*}} -> {:ok, expected_lock_version: :*}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Enforce a parsed `If-Match` instruction against `lock_version`.
  """
  @spec enforce_if_match(if_match(), pos_integer()) :: :ok | {:precondition_failed}
  def enforce_if_match({:any_existing, :*}, _lock_version), do: :ok

  def enforce_if_match({:version, expected}, lock_version) do
    if expected == lock_version, do: :ok, else: {:precondition_failed}
  end

  # ── Controller wiring ─────────────────────────────────────────────────

  @doc """
  Handle the GET-side outcome of `evaluate/2`.

  A matching `If-None-Match` short-circuits with `304 Not Modified` (current
  ETag, no body). Returns the conn untouched when no precondition applies.
  Error outcomes are left to the caller (see `error_detail/1`).
  """
  @spec maybe_send_not_modified(Plug.Conn.t(), precondition()) ::
          Plug.Conn.t() | precondition()
  def maybe_send_not_modified(conn, {:not_modified, etag}) do
    conn
    |> put_resp_header("etag", etag)
    |> send_resp(:not_modified, "")
  end

  def maybe_send_not_modified(_conn, other), do: other

  @doc """
  Human-readable error detail for the `400` outcomes.
  """
  @spec error_detail(:unsupported_header | :invalid_if_match) :: String.t()
  def error_detail(:unsupported_header) do
    "Conditional headers if-modified-since, if-unmodified-since, and if-range are not supported"
  end

  def error_detail(:invalid_if_match) do
    "Invalid If-Match header; expected a quoted lock version or *"
  end

  # ── Internals ─────────────────────────────────────────────────────────

  defp header(conn, name), do: hd(get_req_header(conn, name))

  defp header_present?(conn, name), do: get_req_header(conn, name) != []

  # If-Match side: exactly `*` or a single strong version tag.
  defp parse_if_match_tag(raw) do
    case parse_etag_list(raw) do
      {:ok, ["*"]} -> {:ok, {:any_existing, :*}}
      {:ok, [tag]} -> version_or_invalid(tag)
      _ -> {:error, :invalid_if_match}
    end
  end

  defp version_or_invalid(tag) do
    case parse_version_tag(tag) do
      {:ok, version} -> {:ok, {:version, version}}
      :error -> {:error, :invalid_if_match}
    end
  end

  # If-None-Match side (GET): any listed tag (or `*`) matching the current
  # ETag means the client already holds the current version.
  defp evaluate_if_none_match(raw, lock_version) do
    case parse_etag_list(raw) do
      {:ok, tags} ->
        current = etag(lock_version)

        if current in tags or "*" in tags do
          {:not_modified, current}
        else
          {:ok, nil}
        end

      :error ->
        {:error, :invalid_if_match}
    end
  end

  defp reject_unsupported(conn) do
    if Enum.any?(@unsupported_if_headers, &match?([_ | _], get_req_header(conn, &1))) do
      {:error, :unsupported_header}
    else
      :ok
    end
  end

  # Parses an entity-tag list: `*`, `"1"`, `"1", "2"`. Weak tags (`W/"1"`)
  # and unquoted values are rejected — ETags here are strong validators.
  defp parse_etag_list(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> case do
      [] ->
        :error

      tags ->
        if Enum.all?(tags, &valid_tag?/1), do: {:ok, tags}, else: :error
    end
  end

  defp valid_tag?("*"), do: true
  defp valid_tag?("W/" <> _), do: false
  defp valid_tag?("\"" <> _), do: true
  defp valid_tag?(_), do: false

  defp parse_version_tag("\"" <> rest) do
    case String.split(rest, "\"", parts: 2) do
      [digits, ""] ->
        case Integer.parse(digits) do
          {version, ""} when version >= 1 -> {:ok, version}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_version_tag(_), do: :error
end
