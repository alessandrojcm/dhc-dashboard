defmodule DhcWeb.Plugs.IdempotencyGate do
  @moduledoc """
  Opt-in boundary for idempotent authenticated writes.

  Requests without `Idempotency-Key` pass through unchanged. Keys are scoped to
  the authenticated principal before they are handed to the vendored tracker.
  """

  @behaviour Plug

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn, only: [get_req_header: 2, halt: 1, put_status: 2]

  @impl true
  def init(_options), do: []

  @impl true
  def call(conn, _options) do
    if get_req_header(conn, "idempotency-key") == [] do
      conn
    else
      conn
      |> IdempotencyPlug.call(
        IdempotencyPlug.init(
          tracker:
            Application.get_env(:dhc, :idempotency_tracker, DhcWeb.IdempotencyRequestTracker),
          idempotency_key: {__MODULE__, :scope_key},
          request_payload: {__MODULE__, :request_fingerprint},
          with: {__MODULE__, :render_error},
          cached_headers: [{"idempotent-replayed", "true"}]
        )
      )
    end
  end

  @doc false
  def scope_key(conn, {key, _path_info}) do
    {conn.assigns.current_session.principal.id, key}
  end

  @doc false
  def request_fingerprint(conn) do
    {conn.path_info, IdempotencyPlug.request_payload(conn)}
  end

  @doc false
  def render_error(conn, error) do
    conn
    |> put_status(error.plug_status)
    |> json(%{errors: %{detail: error.message}})
    |> halt()
  end
end
