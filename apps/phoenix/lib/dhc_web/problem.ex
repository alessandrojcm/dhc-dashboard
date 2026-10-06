defmodule DhcWeb.Problem do
  @moduledoc """
  The one renderer for HTTP error bodies (ALE-343).

  Every error leaves the API as

      {"errors": {"detail": "...", "code": "...", "fields": {"publicName": ["..."]}}}

    * `detail` is always present.
    * `code` is the snake_case domain reason, present for **409 and 422
      domain reasons only** — never for a generic 400/401/403/404/500 and never
      for a plain changeset.
    * `fields` maps public camelCase field names to messages whose `%{…}`
      placeholders are already filled in. For a changeset `detail` is built
      from the fields as `"field: message, message; field: message"`.

  ## Per-domain fallback modules

  Each HTTP family declares its reasons once:

      defmodule DhcWeb.InventoryHTTP do
        use DhcWeb.Problem,
          reasons: %{
            item_unavailable: {409, "The item is not available right now"},
            loan_not_found: {404, "Loan not found"}
          },
          fields: %{parent_container_id: "parentContainerId"}
      end

  A reason is `{status, detail}` or `{status, detail, code}` when the wire
  code must differ from the reason name (two reasons sharing one public code).
  Fields not listed in `fields:` are camelCased, so a snake_case key never
  reaches the wire.

  Controllers declare `action_fallback DhcWeb.InventoryHTTP` and return one
  of:

    * `{:error, reason}` — a declared reason, or the shared `:not_found`,
      `:forbidden`, `:unauthorized`;
    * `{:error, reason, fields}` — a declared reason plus field messages
      (`%{"public" => ["message"]}`), e.g. per-definition value failures;
    * `{:error, %Ecto.Changeset{}}` — a 422 with mapped fields;
    * `{:error, [message]}` — a 422 whose detail joins the messages.

  The controller owns translation from a domain result to a reason when one
  family needs two details for the same domain atom; the HTTP module owns the
  status and the detail.

  Plugs (and ALE-344's capability-gated routes) render the shared reasons
  without a fallback module through `send_reason/2`.
  """

  import Plug.Conn

  @default_reasons %{
    unauthorized: {401, "Unauthorized"},
    forbidden: {403, "Insufficient role"},
    not_found: {404, "Not found"}
  }

  @coded_statuses [409, 422]

  @type reason_spec :: {Plug.Conn.status(), String.t()} | {Plug.Conn.status(), String.t(), atom()}
  @type config :: %{reasons: %{atom() => reason_spec()}, fields: %{String.t() => String.t()}}

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Plug

      @problem_config DhcWeb.Problem.config(opts)

      @impl Plug
      def init(opts), do: opts

      @impl Plug
      def call(conn, result), do: DhcWeb.Problem.render_result(conn, result, @problem_config)

      @doc "The reason table and field mapping this module renders with."
      def problem_config, do: @problem_config
    end
  end

  @doc "Builds a fallback configuration from `use DhcWeb.Problem` options."
  @spec config(keyword()) :: config()
  def config(opts \\ []) do
    reasons = Map.merge(@default_reasons, Map.new(Keyword.get(opts, :reasons, %{})))

    for {reason, spec} <- reasons do
      validate_reason!(reason, spec)
    end

    fields =
      opts
      |> Keyword.get(:fields, %{})
      |> Map.new(fn {internal, public} -> {to_string(internal), to_string(public)} end)

    %{reasons: reasons, fields: fields}
  end

  @doc """
  Action-fallback entry point for the shared reasons only; plugs can also use
  it as `DhcWeb.Problem.call(conn, {:error, :forbidden})`.
  """
  def init(opts), do: opts

  def call(conn, result), do: render_result(conn, result, config())

  @doc """
  Renders a shared reason (`:unauthorized`, `:forbidden`, `:not_found`) and
  halts — the entry point for plugs.
  """
  @spec send_reason(Plug.Conn.t(), atom()) :: Plug.Conn.t()
  def send_reason(conn, reason) do
    conn |> render_result({:error, reason}, config()) |> halt()
  end

  @doc """
  Renders a controller result through a configuration. Unknown reasons raise:
  an undeclared reason is a programming error, not a client error.
  """
  @spec render_result(Plug.Conn.t(), term(), config()) :: Plug.Conn.t()
  def render_result(conn, {:error, %Ecto.Changeset{} = changeset}, config) do
    fields = changeset_fields(changeset, config.fields)
    send_problem(conn, 422, %{detail: fields_detail(fields), fields: fields})
  end

  def render_result(conn, {:error, [_ | _] = messages}, _config) do
    if Enum.all?(messages, &is_binary/1) do
      send_problem(conn, 422, %{detail: Enum.join(messages, "; ")})
    else
      raise ArgumentError,
            "DhcWeb.Problem: error lists must hold strings, got #{inspect(messages)}"
    end
  end

  def render_result(conn, {:error, reason}, config) when is_atom(reason) do
    send_problem(conn, status_of(config, reason), reason_body(config, reason))
  end

  def render_result(conn, {:error, reason, fields}, config)
      when is_atom(reason) and is_map(fields) do
    fields =
      Map.new(fields, fn {key, messages} -> {public_field(key, config.fields), messages} end)

    body = config |> reason_body(reason) |> Map.put(:fields, fields)
    send_problem(conn, status_of(config, reason), body)
  end

  def render_result(_conn, other, _config) do
    raise ArgumentError, "DhcWeb.Problem cannot render #{inspect(other)}"
  end

  @doc """
  The body for one status and detail, for renderers that only have a status
  (`DhcWeb.ErrorJSON`) or a detail chosen outside a reason table.
  """
  @spec body(String.t(), keyword()) :: %{errors: map()}
  def body(detail, opts \\ []) when is_binary(detail) do
    errors =
      %{detail: detail}
      |> maybe_put(:code, opts[:code] && to_string(opts[:code]))
      |> maybe_put(:fields, opts[:fields])

    %{errors: errors}
  end

  @doc "Sends `body/2` with `status` without halting."
  @spec send_detail(Plug.Conn.t(), Plug.Conn.status(), String.t(), keyword()) :: Plug.Conn.t()
  def send_detail(conn, status, detail, opts \\ []) do
    conn
    |> put_status(status)
    |> Phoenix.Controller.json(body(detail, opts))
  end

  @doc """
  Maps changeset errors to public field names with placeholders filled in.
  Nested changesets flatten to dotted paths (`values.0.text`).
  """
  @spec changeset_fields(Ecto.Changeset.t(), %{String.t() => String.t()}) ::
          %{String.t() => [String.t()]}
  def changeset_fields(%Ecto.Changeset{} = changeset, mapping \\ %{}) do
    changeset
    |> Ecto.Changeset.traverse_errors(&interpolate/1)
    |> flatten(nil)
    |> Map.new(fn {path, messages} -> {public_field(path, mapping), messages} end)
  end

  @doc "Joins field messages into a `detail` sentence."
  @spec fields_detail(%{String.t() => [String.t()]}) :: String.t()
  def fields_detail(fields) when fields == %{}, do: "Invalid request"

  def fields_detail(fields) do
    fields
    |> Enum.sort()
    |> Enum.map_join("; ", fn {field, messages} -> "#{field}: #{Enum.join(messages, ", ")}" end)
  end

  @doc "Fills `%{key}` placeholders in an Ecto error message."
  @spec interpolate({String.t(), keyword()}) :: String.t()
  def interpolate({message, opts}) do
    Regex.replace(~r/%{(\w+)}/, message, fn placeholder, key ->
      case Enum.find(opts, fn {opt, _value} -> to_string(opt) == key end) do
        {_opt, value} -> placeholder_value(value)
        nil -> placeholder
      end
    end)
  end

  # ── internals ──────────────────────────────────────────────────

  defp send_problem(conn, status, errors) do
    conn
    |> put_status(status)
    |> Phoenix.Controller.json(%{errors: errors})
  end

  defp reason_body(config, reason) do
    {status, detail, code} = spec!(config, reason)
    maybe_put(%{detail: detail}, :code, if(status in @coded_statuses, do: to_string(code)))
  end

  defp status_of(config, reason) do
    {status, _detail, _code} = spec!(config, reason)
    status
  end

  defp spec!(config, reason) do
    case Map.fetch(config.reasons, reason) do
      {:ok, {status, detail}} -> {Plug.Conn.Status.code(status), detail, reason}
      {:ok, {status, detail, code}} -> {Plug.Conn.Status.code(status), detail, code}
      :error -> raise ArgumentError, "DhcWeb.Problem: undeclared error reason #{inspect(reason)}"
    end
  end

  defp validate_reason!(reason, {status, detail}),
    do: validate_reason!(reason, {status, detail, reason})

  defp validate_reason!(reason, {status, detail, code})
       when is_atom(reason) and is_binary(detail) and is_atom(code) do
    _ = Plug.Conn.Status.code(status)
    :ok
  end

  defp validate_reason!(reason, spec) do
    raise ArgumentError, "DhcWeb.Problem: invalid reason #{inspect(reason)} => #{inspect(spec)}"
  end

  defp flatten(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} -> flatten(value, join(prefix, key)) end)
  end

  defp flatten([first | _] = messages, prefix) when is_binary(first), do: [{prefix, messages}]

  defp flatten(list, prefix) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {nested, index} -> flatten(nested, join(prefix, index)) end)
  end

  defp join(nil, key), do: to_string(key)
  defp join(prefix, key), do: "#{prefix}.#{key}"

  defp public_field(path, mapping) do
    path = to_string(path)

    case Map.fetch(mapping, path) do
      {:ok, public} ->
        public

      :error ->
        path |> String.split(".") |> Enum.map_join(".", &camelize/1)
    end
  end

  defp camelize(segment) do
    case String.split(segment, "_") do
      [first | rest] -> first <> Enum.map_join(rest, &String.capitalize/1)
    end
  end

  defp placeholder_value(value) when is_binary(value) or is_number(value) or is_atom(value),
    do: to_string(value)

  defp placeholder_value(value), do: inspect(value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
