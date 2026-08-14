defmodule DhcWeb.AuthSessionController do
  @moduledoc """
  Phoenix-owned authentication API (ALE-165).

  Phoenix-owned session endpoints, non-enumerating where the spec requires:

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
       Inactive Principals receive `403` with a clear membership message;
       Authentication consumes the proof but atomically declines to mint a
       Session.
    * `GET /api/auth/session` — return the current session projection. Used
      by SvelteKit SSR and the browser to read who is signed in. Returns
      `401` when there is no valid session.
    * `DELETE /api/auth/session` — sign out the current device. Deletes the
      session token row, clears the cookie. Idempotent.
     * `GET /api/auth/discord` and `/api/auth/discord/callback` — complete the
       Discord OAuth flow, establish a Phoenix session for an eligible linked
       Principal, and redirect back to the dashboard.
     * `GET /api/auth/discord/link` — start an authenticated Discord-link flow.
       The initiating Session is revalidated when Discord calls back.

  ## Cookie contract

  The `_dhc_session` cookie is signed by the Phoenix endpoint, with
  `Secure`, `HttpOnly`, `SameSite=Lax`, `Path=/`, and a 30-day `max_age`
  matching the absolute session lifetime. The domain is `.dublinhemaclub.com`
  in production (configurable via `:auth_session_domain`) so SvelteKit SSR
  and the browser share it. In dev/test the domain is omitted (localhost).
  """

  use DhcWeb, :controller

  import Plug.Conn
  require Logger

  alias Dhc.Auth
  alias DhcWeb.AuthSessionJSON

  @session_cookie "_dhc_session"
  # 30-day absolute — must match `Dhc.Auth.PrincipalToken`'s
  # `@session_validity_in_days`.
  @session_max_age 30 * 24 * 60 * 60

  @discord_oauth_flow_session_key :discord_oauth_flow

  # ── GET /api/auth/discord ────────────────────────────────────────────
  def request_discord(conn, _params) do
    conn
    |> authorize_discord(:sign_in)
  end

  # This flow is deliberately separate from sign-in and linking. The opaque
  # continuation remains in the protected browser session and is never placed
  # in Discord state or a redirect URL.
  def request_acceptance_discord(conn, continuation_id) do
    authorize_discord(conn, {:invitation_acceptance, continuation_id})
  end

  def request_discord_link(conn, _params) do
    session_token = conn.assigns.current_session_token

    case Auth.get_session_reference(session_token) do
      {:ok, session_reference} ->
        conn
        |> authorize_discord({:link, session_reference})

      {:error, :invalid} ->
        conn
        |> put_status(:unauthorized)
        |> render_view(:error, %{error: "Unauthorized"})
    end
  end

  # The purpose and Assent's state/PKCE session parameters are persisted as
  # one browser-session value. The browser never supplies the purpose during
  # the callback, so it cannot turn a sign-in into a link (or vice versa).
  # Starting another Discord flow replaces this value; only the most recently
  # started flow may complete.
  defp authorize_discord(conn, purpose) do
    strategy = discord_strategy()

    case strategy.authorize_url(discord_config(purpose)) do
      {:ok, %{url: url, session_params: session_params}} ->
        conn
        |> put_session(@discord_oauth_flow_session_key, %{
          purpose: purpose,
          session_params: session_params
        })
        |> redirect(external: url)

      {:error, _reason} ->
        discord_failure(conn)
    end
  end

  def discord_callback(conn, params) do
    flow = get_session(conn, @discord_oauth_flow_session_key)

    conn =
      conn
      |> Plug.Conn.delete_session(@discord_oauth_flow_session_key)

    case valid_discord_oauth_flow(flow) do
      {:ok, purpose, session_params} ->
        case complete_discord_oauth_callback(params, session_params, purpose) do
          {:ok, %{user: claims}} -> complete_discord_auth(conn, purpose, claims)
          {:error, _reason} -> complete_discord_callback_failure(conn, purpose, params)
        end

      {:error, :invalid_purpose} ->
        :telemetry.execute([:dhc, :auth, :discord, :failed], %{}, %{})
        log_discord_failure("oauth_purpose")
        discord_failure(conn)
    end
  end

  defp complete_discord_callback_failure(conn, {:invitation_acceptance, continuation_id}, params) do
    outcome = if params["error"] == "access_denied", do: :cancelled, else: :failed
    _ = Dhc.Onboarding.fail_discord(continuation_id, outcome)
    acceptance_resume(conn, continuation_id)
  end

  defp complete_discord_callback_failure(conn, _purpose, _params) do
    :telemetry.execute([:dhc, :auth, :discord, :failed], %{}, %{})
    log_discord_failure("oauth_callback")
    discord_failure(conn)
  end

  defp valid_discord_oauth_flow(%{purpose: :sign_in, session_params: session_params})
       when is_map(session_params),
       do: {:ok, :sign_in, session_params}

  defp valid_discord_oauth_flow(%{
         purpose: {:link, session_reference},
         session_params: session_params
       })
       when is_binary(session_reference) and is_map(session_params),
       do: {:ok, {:link, session_reference}, session_params}

  defp valid_discord_oauth_flow(%{
         purpose: {:invitation_acceptance, continuation_id},
         session_params: session_params
       })
       when is_binary(continuation_id) and is_map(session_params),
       do: {:ok, {:invitation_acceptance, continuation_id}, session_params}

  defp valid_discord_oauth_flow(_flow), do: {:error, :invalid_purpose}

  defp complete_discord_oauth_callback(params, session_params, purpose) do
    discord_config(purpose)
    |> Keyword.put(:session_params, session_params)
    |> discord_strategy().callback(params)
  end

  defp complete_discord_auth(conn, :sign_in, claims) do
    case Auth.sign_in_with_discord(claims) do
      {:ok, %{session_token: session_token}} ->
        :telemetry.execute([:dhc, :auth, :discord, :succeeded], %{}, %{})

        Logger.info("[auth] Discord sign-in succeeded",
          provider: "discord",
          outcome: "succeeded"
        )

        app_url = Application.get_env(:dhc, :app_url, "http://localhost:5173")

        conn
        |> put_session_cookie(session_token)
        |> redirect(external: "#{app_url}/dashboard")

      {:error, :invalid} ->
        :telemetry.execute([:dhc, :auth, :discord, :failed], %{}, %{})
        log_discord_failure("account_validation")
        discord_failure(conn)
    end
  end

  defp complete_discord_auth(conn, {:link, session_reference}, claims) do
    with {:ok, principal} <- Auth.get_principal_by_session_reference(session_reference),
         {:ok, %{is_active: true}} <- Auth.load_session_principal(principal),
         {:ok, _identity} <- Auth.link_discord_identity(principal, claims) do
      :telemetry.execute([:dhc, :auth, :discord, :linked], %{}, %{})
      app_url = Application.get_env(:dhc, :app_url, "http://localhost:5173")
      redirect(conn, external: "#{app_url}/dashboard")
    else
      _error ->
        :telemetry.execute([:dhc, :auth, :discord, :failed], %{}, %{})
        log_discord_failure("account_validation")
        discord_failure(conn)
    end
  end

  defp complete_discord_auth(conn, {:invitation_acceptance, continuation_id}, claims) do
    case Dhc.Onboarding.verify_discord(continuation_id, claims) do
      {:ok, _safe_state} -> acceptance_resume(conn, continuation_id)
      {:error, :collision} -> acceptance_resume(conn, continuation_id)
      {:error, _} -> acceptance_failure(conn, continuation_id)
    end
  end

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
      {:ok, %{session_token: session_token, session: projection}} ->
        :telemetry.execute([:dhc, :auth, :magic_link, :succeeded], %{}, %{})

        conn
        |> put_session_cookie(session_token)
        |> put_status(:ok)
        |> render_view(:session, %{session: projection})

      {:error, :invalid} ->
        :telemetry.execute([:dhc, :auth, :magic_link, :failed], %{}, %{})
        unauthorized_link(conn)

      {:error, :inactive_membership} ->
        :telemetry.execute([:dhc, :auth, :magic_link, :inactive], %{}, %{})

        conn
        |> put_status(:forbidden)
        |> render_view(:error, %{
          error: "Your membership is inactive. Please contact the club to restore access."
        })
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

  # ── GET /api/auth/socket-token ──────────────────────────────────────
  # ALE-164: the dashboard browser cannot read the HTTP-only `_dhc_session`
  # cookie to pass it via the Phoenix JS `authToken` socket option, and
  # `new WebSocket(url, protocols)` has no `withCredentials` so a cross-origin
  # socket cannot send the cookie. This endpoint exchanges the cookie for a
  # short-lived, JS-readable, DB-backed socket token the browser can pass as
  # `authToken`. `UserSocket.connect/3` verifies it via the same
  # `Dhc.Auth.get_principal_by_socket_token/1` boundary.
  def socket_token(conn, _params) do
    principal = conn.assigns.current_session.principal

    {:ok, token} = Auth.create_socket_token(principal)

    conn
    |> put_status(:ok)
    |> json(%{data: %{socketToken: Base.url_encode64(token, padding: false)}})
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
      secure: Application.get_env(:dhc, :auth_session_secure, false),
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

  defp discord_strategy do
    Application.get_env(:dhc, :discord_oauth_strategy, Assent.Strategy.Discord)
  end

  defp discord_config do
    Application.get_env(:dhc, :discord_oauth, [])
  end

  defp discord_config({:invitation_acceptance, _continuation_id}) do
    Keyword.put(
      discord_config(),
      :redirect_uri,
      Application.fetch_env!(:dhc, :invitation_acceptance_discord_redirect_uri)
    )
  end

  defp discord_config(_purpose), do: discord_config()

  defp discord_failure(conn) do
    app_url = Application.get_env(:dhc, :app_url, "http://localhost:5173")
    redirect(conn, external: "#{app_url}/auth?discord=failed")
  end

  defp acceptance_resume(conn, continuation_id) do
    app_url = Application.get_env(:dhc, :app_url, "http://localhost:5173")

    case Dhc.Onboarding.acceptance_oauth_resume_path(continuation_id) do
      {:ok, path} -> redirect(conn, external: app_url <> path)
      {:error, _} -> redirect(conn, external: app_url <> "/members/signup/restart")
    end
  end

  defp acceptance_failure(conn, continuation_id) do
    # Do not expose provider or continuation diagnostics. The local status view
    # decides which neutral restart state to show.
    acceptance_resume(conn, continuation_id)
  end

  defp log_discord_failure(stage) do
    Logger.warning("[auth] Discord sign-in failed at #{stage}",
      provider: "discord",
      outcome: "failed",
      failure_stage: stage
    )
  end

  defp render_view(conn, template, assigns \\ %{})

  defp render_view(conn, :sent, _assigns), do: json(conn, AuthSessionJSON.sent(%{}))

  defp render_view(conn, :session, assigns),
    do: json(conn, AuthSessionJSON.session(assigns))

  defp render_view(conn, :error, %{error: detail}),
    do: json(conn, AuthSessionJSON.error(detail))
end
