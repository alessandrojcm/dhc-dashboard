defmodule DhcWeb.AuthSessionController do
  @moduledoc """
  Phoenix-owned authentication API (ALE-165).

  Three endpoints, all JSON, all non-enumerating where the spec requires:

    * `POST /api/auth/magic-link` — request a magic link. Always returns
      `200 {"data":{"sent":true}}` for a well-formed email. The
      `MagicLinkRateLimit` plug (in the pipeline) refuses over-the-limit
      requests with the same 200 body. Email delivery is enqueued via
      `Dhc.Email.Worker` only when a Principal exists.
    * `POST /api/auth/magic-link/verify` — consume a magic link. On success,
      sets the signed `_dhc_session` cookie and returns the session
      projection. On failure, returns `401 {"errors":{"detail":"Invalid or
      expired link"}}` — the same response the rate-limit and unknown-email
      paths would produce if they were distinguishable, which they are not.
      Refuses inactive Principals with `401` (no session minted).
    * `GET /api/auth/session` — return the current session projection. Used
      by SvelteKit SSR and the browser to read who is signed in. Returns
      `401` when there is no valid session.
    * `DELETE /api/auth/session` — sign out the current device. Deletes the
      session token row, clears the cookie. Idempotent.

  ## Cookie contract

  The `_dhc_session` cookie is signed by the Phoenix endpoint, with
  `Secure`, `HttpOnly`, `SameSite=Lax`, `Path=/`, and a 30-day `max_age`
  matching the absolute session lifetime. The domain is `.dublinhemaclub.com`
  in production (configurable via `:auth_session_domain`) so SvelteKit SSR
  and the browser share it. In dev/test the domain is omitted (localhost).
  """

  use DhcWeb, :controller

  import Plug.Conn

  alias Dhc.Auth
  alias DhcWeb.AuthSessionJSON

  @session_cookie "_dhc_session"
  # 30-day absolute — must match `Dhc.Auth.PrincipalToken`'s
  # `@session_validity_in_days`.
  @session_max_age 30 * 24 * 60 * 60

  # ── POST /api/auth/magic-link ────────────────────────────────────────
  def request_magic_link(conn, %{"email" => email} = _params) when is_binary(email) do
    # The rate-limit plug runs before this controller and has already
    # decided the request is allowed through. We still call
    # `Auth.deliver_magic_link/2`, which returns `{:ok, :sent}` for any
    # well-formed email (enqueues the email only if a Principal exists).
    # The magic-link URL points back at the dashboard's magic-link verify
    # endpoint (the SvelteKit side will host the UI that POSTs the token
    # here). The frontend base URL is configurable.
    frontend_base = Application.get_env(:dhc, :app_url, "http://localhost:5173")
    magic_link_url_fun = fn token -> "#{frontend_base}/auth/magic-link?token=#{token}" end

    {:ok, :sent} = Auth.deliver_magic_link(email, magic_link_url_fun)

    # Telemetry: aggregate, non-personal. The plug emits :rate_limited;
    # this is the success path (whether or not a Principal existed).
    :telemetry.execute([:dhc, :auth, :magic_link, :requested], %{}, %{})

    conn
    |> put_status(:ok)
    |> render_view(:sent)
  end

  # Malformed payload — still non-enumerating. The rate-limit plug already
  # returned its own generic 200 for the no-email case, so this branch only
  # fires when the plug did not (e.g. the email field is missing and the
  # plug's `{:error, :no_email}` short-circuit didn't run, which can't happen
  # with the current pipeline order — kept defensive).
  def request_magic_link(conn, _params) do
    conn
    |> put_status(:ok)
    |> render_view(:sent)
  end

  # ── POST /api/auth/magic-link/verify ─────────────────────────────────
  def verify_magic_link(conn, %{"token" => token} = _params) when is_binary(token) do
    case Auth.consume_magic_link(token) do
      {:ok, %{principal: principal, session_token: session_token}} ->
        # Access check: a Principal may establish a session only while its
        # Member has club access. `load_session_principal/1` gives us
        # `is_active` without a second context. An inactive Principal never
        # gets a cookie.
        case Auth.load_session_principal(principal) do
          {:ok, %{is_active: true} = projection} ->
            :telemetry.execute([:dhc, :auth, :magic_link, :succeeded], %{}, %{})

            conn
            |> put_session_cookie(session_token)
            |> put_status(:ok)
            |> render_view(:session, %{session: projection})

          _ ->
            # Inactive or no profile — revoke the session we just minted
            # and respond 401. Non-enumerating: same body as an invalid
            # token.
            Auth.delete_session_token(session_token)
            :telemetry.execute([:dhc, :auth, :magic_link, :inactive_principal], %{}, %{})

            conn
            |> put_status(:unauthorized)
            |> render_view(:error, %{error: "Invalid or expired link"})
        end

      {:error, :invalid} ->
        :telemetry.execute([:dhc, :auth, :magic_link, :failed], %{}, %{})
        unauthorized_link(conn)
    end
  end

  def verify_magic_link(conn, _params), do: unauthorized_link(conn)

  defp unauthorized_link(conn) do
    conn
    |> put_status(:unauthorized)
    |> render_view(:error, %{error: "Invalid or expired link"})
  end

  # ── GET /api/auth/session ────────────────────────────────────────────
  def show_session(conn, _params) do
    # The :authenticated_session_api pipeline (RequireSession) has already
    # populated `current_session`. If we got here, the session is valid and
    # active.
    projection = conn.assigns.current_session

    conn
    |> put_status(:ok)
    |> render_view(:session, %{session: projection})
  end

  # ── DELETE /api/auth/session ─────────────────────────────────────────
  def delete_session(conn, _params) do
    # Idempotent: works whether or not the cookie is present. If the
    # pipeline required a session, the token is in
    # `current_session_token`; if this route is public (it currently isn't),
    # we'd read the cookie directly.
    token = conn.assigns[:current_session_token] || session_token_from_cookie(conn)

    if token, do: Auth.delete_session_token(token)

    conn
    |> delete_resp_cookie(@session_cookie, cookie_opts())
    |> put_status(:ok)
    |> json(%{data: %{signed_out: true}})
  end

  defp session_token_from_cookie(conn) do
    conn = fetch_cookies(conn, signed: [@session_cookie])
    conn.cookies[@session_cookie]
  end

  defp put_session_cookie(conn, token) do
    put_resp_cookie(conn, @session_cookie, token, cookie_opts())
  end

  defp cookie_opts do
    [
      sign: true,
      http_only: true,
      same_site: "Lax",
      path: "/",
      max_age: @session_max_age
    ] ++ domain_opt()
  end

  defp domain_opt do
    case Application.get_env(:dhc, :auth_session_domain) do
      nil -> []
      domain -> [domain: domain]
    end
  end

  defp render_view(conn, template, assigns \\ %{})

  defp render_view(conn, :sent, _assigns), do: json(conn, AuthSessionJSON.sent(%{}))

  defp render_view(conn, :session, assigns),
    do: json(conn, AuthSessionJSON.session(assigns))

  defp render_view(conn, :error, %{error: detail}),
    do: json(conn, AuthSessionJSON.error(detail))
end
