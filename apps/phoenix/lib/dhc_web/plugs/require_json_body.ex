defmodule DhcWeb.Plugs.RequireJsonBody do
  @moduledoc """
  Rejects state-changing API requests whose body is not JSON (415).

  The session cookie is `SameSite=Lax` on `.dublinhemaclub.com`, so an HTML
  form on any sibling subdomain is *same-site*: it carries the cookie and can
  submit a "simple" cross-origin request (`application/x-www-form-urlencoded`,
  `multipart/form-data` or `text/plain`) without a CORS preflight. Requiring a
  JSON content type on every `POST`/`PUT`/`PATCH`/`DELETE` that carries a body
  forces such a request through a preflight, which `DhcWeb.Plugs.Cors` only
  answers for allowed origins.

  Rules for an unsafe method:

    * a `content-type` header is present → it must be `application/json` or
      `application/*+json` (parameters such as `charset` are ignored). This
      also covers an empty form submission, which still sends a form content
      type;
    * no `content-type` header → allowed only when the request has no body
      (no `transfer-encoding`, and `content-length` absent or `0`). Several
      routes are bodyless `POST`/`DELETE` commands.

  Every route in the OpenAPI contract takes JSON; no route accepts another
  content type, so there is no allow-list. A route that legitimately needs one
  must be served by a pipeline without this plug.
  """

  @behaviour Plug

  import Plug.Conn

  @problem_config DhcWeb.Problem.config(
                    reasons: %{
                      unsupported_media_type: {415, "Request body must be application/json"}
                    }
                  )

  @unsafe_methods ~w(POST PUT PATCH DELETE)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: method} = conn, _opts) when method in @unsafe_methods do
    if acceptable?(conn), do: conn, else: reject(conn)
  end

  def call(conn, _opts), do: conn

  defp acceptable?(conn) do
    case get_req_header(conn, "content-type") do
      [content_type | _] -> json_media_type?(content_type)
      [] -> bodyless?(conn)
    end
  end

  defp json_media_type?(content_type) do
    case Plug.Conn.Utils.media_type(content_type) do
      {:ok, "application", "json", _params} -> true
      {:ok, "application", subtype, _params} -> String.ends_with?(subtype, "+json")
      _ -> false
    end
  end

  defp bodyless?(conn) do
    get_req_header(conn, "transfer-encoding") == [] and
      get_req_header(conn, "content-length") in [[], ["0"]]
  end

  defp reject(conn) do
    conn
    |> DhcWeb.Problem.render_result({:error, :unsupported_media_type}, @problem_config)
    |> halt()
  end
end
