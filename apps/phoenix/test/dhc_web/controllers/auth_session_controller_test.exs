defmodule DhcWeb.AuthSessionControllerTest do
  use DhcWeb.ConnCase, async: true

  import Dhc.AuthFixtures
  alias Dhc.Auth.PrincipalToken
  alias Dhc.Repo

  import Ecto.Query

  @session_cookie "_dhc_session"

  describe "GET /api/auth/discord" do
    test "starts Discord OAuth with state stored in the Phoenix session" do
      conn = get(conn(), "/api/auth/discord")

      assert redirected_to(conn, 302) ==
               "https://discord.example.com/oauth2/authorize?state=test-state"

      assert get_session(conn, :discord_oauth_session_params) == %{state: "test-state"}
    end
  end

  describe "GET /api/auth/discord/callback" do
    test "links a verified Discord identity, sets a Phoenix Session, and redirects to dashboard" do
      principal = active_principal("discord-request@example.com")

      conn =
        conn()
        |> get("/api/auth/discord")
        |> recycle()
        |> get("/api/auth/discord/callback?state=test-state&code=success")

      assert redirected_to(conn, 302) == "http://localhost:5173/dashboard"
      assert conn.resp_cookies[@session_cookie]

      identity =
        Repo.get_by!(Dhc.Auth.ExternalIdentity,
          provider: "discord",
          provider_subject: "discord-request-success"
        )

      assert identity.principal_id == principal.id
      refute Map.has_key?(identity.metadata, "access_token")
    end

    test "uses the same generic magic-link fallback for invalid state and unknown accounts" do
      invalid_state = get(conn(), "/api/auth/discord/callback?state=wrong&code=success")

      unknown =
        conn()
        |> get("/api/auth/discord")
        |> recycle()
        |> get("/api/auth/discord/callback?state=test-state&code=unknown")

      assert redirected_to(invalid_state, 302) == "http://localhost:5173/auth?discord=failed"
      assert redirected_to(unknown, 302) == "http://localhost:5173/auth?discord=failed"
      refute invalid_state.resp_cookies[@session_cookie]
      refute unknown.resp_cookies[@session_cookie]
      refute Repo.exists?(Dhc.Auth.ExternalIdentity)

      conn = post(conn(), "/api/auth/magic-link", %{"email" => "unknown-discord@example.com"})
      assert %{"data" => %{"sent" => true}} = json_response(conn, 200)
    end
  end

  # ── POST /api/auth/magic-link ─────────────────────────────────────────

  describe "POST /api/auth/magic-link — non-enumerating response" do
    test "returns 200 {sent: true} for a known active Principal" do
      principal = principal_fixture()

      conn = post(conn(), "/api/auth/magic-link", %{"email" => principal.email})

      assert %{"data" => %{"sent" => true}} = json_response(conn, 200)
    end

    test "returns the same 200 {sent: true} for an unknown email" do
      conn = post(conn(), "/api/auth/magic-link", %{"email" => "nobody@example.com"})
      assert %{"data" => %{"sent" => true}} = json_response(conn, 200)
    end

    test "returns the same 200 {sent: true} for a malformed payload" do
      conn = post(conn(), "/api/auth/magic-link", %{})
      assert %{"data" => %{"sent" => true}} = json_response(conn, 200)
    end

    test "enqueues a Loops email job for a known Principal only" do
      known = principal_fixture()
      unknown_email = "unknown-#{System.unique_integer([:positive])}@example.com"

      initial = oban_jobs_count()

      post(conn(), "/api/auth/magic-link", %{"email" => known.email})
      post(conn(), "/api/auth/magic-link", %{"email" => unknown_email})

      # Exactly one job enqueued (for the known Principal).
      assert oban_jobs_count() == initial + 1

      [job] =
        Repo.all(
          from(j in "oban_jobs",
            order_by: [desc: j.id],
            limit: 1,
            select: %{id: j.id, args: j.args}
          )
        )

      # The args carry the friendly name and the recipient email — no token
      # in the args (the token is in the URL data variable). The data
      # variable key is `LoginLink` to match the Loops "magic link"
      # transactional template (`cma3yqgqw68tv9pm5v0si5ge3`).
      assert job.args["transactional_id"] == "magicLink"
      assert job.args["email"] == known.email
      assert Map.has_key?(job.args["data_variables"], "LoginLink")
      refute Map.has_key?(job.args["data_variables"], "url")
    end
  end

  describe "POST /api/auth/magic-link — rate limiting" do
    test "allows up to 3 requests per email per 15 minutes, then short-circuits" do
      email = "limited-#{System.unique_integer([:positive])}@example.com"

      # First three are accepted (return the same body either way — we
      # verify by side effect: a known Principal receives an email job only
      # while the request is allowed through).
      principal_fixture(email: email)

      for _ <- 1..3 do
        conn = post(conn(), "/api/auth/magic-link", %{"email" => email})
        assert %{"data" => %{"sent" => true}} = json_response(conn, 200)
      end

      initial_jobs = oban_jobs_count()

      # 4th request is rate-limited: same body, but no email job enqueued.
      conn = post(conn(), "/api/auth/magic-link", %{"email" => email})
      assert %{"data" => %{"sent" => true}} = json_response(conn, 200)
      # The known Principal exists, so without the rate limit a job would
      # have been enqueued. Asserting the oban_jobs count did not increase
      # proves the plug halted before reaching the controller.
      assert oban_jobs_count() == initial_jobs
    end

    test "counts a known and an unknown email identically (no enumeration via rate limit)" do
      # An unknown address also burns one of the 3-per-email slots; otherwise
      # an attacker could distinguish "unknown but accepted" from "known but
      # limited". We assert the 4th request for an unknown email also
      # returns the generic body.
      email = "unknown-limited-#{System.unique_integer([:positive])}@example.com"

      for _ <- 1..3 do
        conn = post(conn(), "/api/auth/magic-link", %{"email" => email})
        assert %{"data" => %{"sent" => true}} = json_response(conn, 200)
      end

      conn = post(conn(), "/api/auth/magic-link", %{"email" => email})
      assert %{"data" => %{"sent" => true}} = json_response(conn, 200)
    end
  end

  # ── POST /api/auth/magic-link/verify ──────────────────────────────────

  describe "POST /api/auth/magic-link/verify" do
    setup do
      # Build a full active member: auth.users + user_profiles + member_profiles
      # + user_roles + a Principal sharing the auth.users UUID (post-M1 shape).
      auth_user_id = Ecto.UUID.generate()
      email = "active-#{System.unique_integer([:positive])}@example.com"

      Dhc.MemberFixtures.member_fixture(%{
        auth_user_id: auth_user_id,
        is_active: true,
        email: email
      })

      Repo.insert_all("user_roles", [[user_id: Ecto.UUID.dump!(auth_user_id), role: "member"]])

      principal = principal_fixture(id: auth_user_id, email: email)
      {:ok, principal: principal}
    end

    test "sets the session cookie and returns the projection for a valid token",
         %{principal: principal} do
      {encoded, _} = magic_link_token(principal)

      conn = post(conn(), "/api/auth/magic-link/verify", %{"token" => encoded})

      assert %{"data" => data} = json_response(conn, 200)
      assert data["principal"]["id"] == principal.id
      assert data["principal"]["email"] == principal.email
      assert "member" in data["roles"]

      # The signed cookie is set. We can't read its raw value through
      # fetch_cookies here (the response cookie is signed), but a follow-up
      # GET /api/auth/session using the same conn's cookies should work.
      assert conn.resp_cookies[@session_cookie]
    end

    test "401 for an invalid token" do
      conn = post(conn(), "/api/auth/magic-link/verify", %{"token" => "garbage"})
      assert %{"errors" => %{"detail" => _}} = json_response(conn, 401)
    end

    test "401 for an expired token", %{principal: principal} do
      {encoded, row} = magic_link_token(principal)
      age_token(row.token, -16, :minute)

      conn = post(conn(), "/api/auth/magic-link/verify", %{"token" => encoded})
      assert %{"errors" => %{"detail" => _}} = json_response(conn, 401)
    end

    test "401 for a reused token", %{principal: principal} do
      {encoded, _} = magic_link_token(principal)

      assert %{"data" => _} =
               post(conn(), "/api/auth/magic-link/verify", %{"token" => encoded})
               |> json_response(200)

      conn = post(conn(), "/api/auth/magic-link/verify", %{"token" => encoded})
      assert %{"errors" => %{"detail" => _}} = json_response(conn, 401)
    end

    test "401 (no session minted) for an inactive Principal" do
      auth_user_id = Ecto.UUID.generate()
      email = "inactive-#{System.unique_integer([:positive])}@example.com"

      Dhc.MemberFixtures.member_fixture(%{
        auth_user_id: auth_user_id,
        is_active: false,
        email: email
      })

      principal = principal_fixture(id: auth_user_id, email: email)
      {encoded, _} = magic_link_token(principal)

      conn = post(conn(), "/api/auth/magic-link/verify", %{"token" => encoded})
      assert %{"errors" => %{"detail" => _}} = json_response(conn, 401)

      # No session row was minted for the inactive principal.
      refute Repo.exists?(
               from(t in PrincipalToken,
                 where: [principal_id: ^principal.id, context: "session"]
               )
             )
    end

    test "401 for an unknown Principal (token has no row)" do
      conn =
        post(conn(), "/api/auth/magic-link/verify", %{
          "token" => "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        })

      assert %{"errors" => %{"detail" => _}} = json_response(conn, 401)
    end
  end

  # ── GET /api/auth/session ─────────────────────────────────────────────

  describe "GET /api/auth/session" do
    test "401 without a session cookie" do
      conn = get(conn(), "/api/auth/session")
      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "401 with a session cookie for an inactive Principal" do
      auth_user_id = Ecto.UUID.generate()
      email = "inactive-session-#{System.unique_integer([:positive])}@example.com"

      Dhc.MemberFixtures.member_fixture(%{
        auth_user_id: auth_user_id,
        is_active: false,
        email: email
      })

      principal = principal_fixture(id: auth_user_id, email: email)
      token = session_token(principal)

      conn =
        conn()
        |> put_signed_cookie(@session_cookie, token)
        |> get("/api/auth/session")

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "200 with the session projection for a valid active session" do
      auth_user_id = Ecto.UUID.generate()
      email = "sess-#{System.unique_integer([:positive])}@example.com"

      Dhc.MemberFixtures.member_fixture(%{
        auth_user_id: auth_user_id,
        is_active: true,
        email: email
      })

      Repo.insert_all("user_roles", [[user_id: Ecto.UUID.dump!(auth_user_id), role: "member"]])

      principal = principal_fixture(id: auth_user_id, email: email)
      token = session_token(principal)

      conn =
        conn()
        |> put_signed_cookie(@session_cookie, token)
        |> get("/api/auth/session")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["principal"]["id"] == principal.id
      assert data["principal"]["email"] == principal.email
      assert "member" in data["roles"]
    end

    test "401 with a session cookie whose Principal has no user_profile" do
      # A Principal exists and has a session, but no user_profiles row.
      principal = principal_fixture()
      token = session_token(principal)

      conn =
        conn()
        |> put_signed_cookie(@session_cookie, token)
        |> get("/api/auth/session")

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end
  end

  # ── 401 vs 403 ────────────────────────────────────────────────────────

  describe "401 vs 403 distinction" do
    # We exercise this through a route guarded by a role-restricted pipeline.
    # GET /api/auth/session is open to any active session; to test 403, we
    # add a temporary route at test time by hitting the existing admin-only
    # /api/members with a Phoenix session cookie carrying only the "member"
    # role — but /api/members is still on the Supabase-JWT RequireAuth plug
    # (ALE-165 defers cutover). Instead, we verify the RequireSession plug
    # directly via a dedicated test route that we mount below.
    #
    # See `DhcWeb.Plugs.RequireSessionTest` for the 403 assertion.
  end

  # ── GET /api/auth/socket-token ───────────────────────────────────────

  describe "GET /api/auth/socket-token" do
    @tag :ale_164
    test "200 with a short-lived socket token for a valid active session" do
      auth_user_id = Ecto.UUID.generate()
      email = "socket-#{System.unique_integer([:positive])}@example.com"

      Dhc.MemberFixtures.member_fixture(%{
        auth_user_id: auth_user_id,
        is_active: true,
        email: email
      })

      Repo.insert_all("user_roles", [[user_id: Ecto.UUID.dump!(auth_user_id), role: "member"]])

      principal = principal_fixture(id: auth_user_id, email: email)
      token = session_token(principal)

      conn =
        conn()
        |> put_signed_cookie(@session_cookie, token)
        |> get("/api/auth/socket-token")

      assert %{"data" => %{"socketToken" => socket_token}} = json_response(conn, 200)
      assert is_binary(socket_token) and socket_token != ""
    end

    @tag :ale_164
    test "401 without a session cookie" do
      conn = get(conn(), "/api/auth/socket-token")
      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end
  end

  # ── DELETE /api/auth/session ──────────────────────────────────────────

  describe "DELETE /api/auth/session" do
    test "signs out the current device and clears the cookie" do
      auth_user_id = Ecto.UUID.generate()
      email = "signout-#{System.unique_integer([:positive])}@example.com"

      Dhc.MemberFixtures.member_fixture(%{
        auth_user_id: auth_user_id,
        is_active: true,
        email: email
      })

      principal = principal_fixture(id: auth_user_id, email: email)
      token = session_token(principal)

      conn =
        conn()
        |> put_signed_cookie(@session_cookie, token)
        |> delete("/api/auth/session")

      assert %{"data" => %{"signed_out" => true}} = json_response(conn, 200)

      # The session token is gone — a follow-up GET is 401.
      conn2 =
        conn()
        |> put_signed_cookie(@session_cookie, token)
        |> get("/api/auth/session")

      assert json_response(conn2, 401)
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  # Builds a signed `_dhc_session` cookie value the way the controller does,
  # so `RequireSession`'s `fetch_cookies(signed: [...])` can verify it. We
  # use `Plug.Conn.put_resp_cookie/4` with `sign: true` on a conn with the
  # endpoint's secret_key_base, then read the value back out of
  # `resp_cookies` (where Plug stores the to-send signed string under
  # `:value`). The conn handed back also carries the secret_key_base so a
  # downstream `fetch_cookies(signed: [...])` can verify the signature.
  defp put_signed_cookie(conn, key, value) do
    secret = DhcWeb.Endpoint.config(:secret_key_base)

    signer_conn =
      conn
      |> Map.replace!(:secret_key_base, secret)
      |> Plug.Conn.put_resp_cookie(key, value,
        sign: true,
        max_age: 30 * 24 * 60 * 60
      )

    signed_value = signer_conn.resp_cookies[key].value

    conn
    |> Map.replace!(:secret_key_base, secret)
    |> put_req_cookie(key, signed_value)
  end

  defp oban_jobs_count do
    Repo.aggregate("oban_jobs", :count)
  end

  defp active_principal(email) do
    id = Ecto.UUID.generate()

    Dhc.MemberFixtures.member_fixture(%{auth_user_id: id, is_active: true, email: email})
    Repo.insert_all("user_roles", [[user_id: Ecto.UUID.dump!(id), role: "member"]])
    principal_fixture(id: id, email: email)
  end
end
