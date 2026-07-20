defmodule DhcWeb.UserSocketTest do
  use DhcWeb.ChannelCase, async: false

  # Socket connect/3 authentication is pure (no DB), but we keep async: false to
  # match ConnCase's auth tests and avoid any cross-test Application.put_env
  # races on :auth_verifier.

  import Dhc.AuthFixtures
  import Phoenix.ChannelTest

  alias Dhc.Repo

  @user_id "11111111-1111-1111-1111-111111111111"
  @other_user_id "22222222-2222-2222-2222-222222222222"

  # Verifier substitution mirroring DhcWeb.NotificationsControllerTest's
  # in-test Verifier module. Resolved through the configured :auth_verifier
  # seam so socket connect/3 tests use the same boundary as HTTP auth tests.
  defmodule Verifier do
    def verify("valid-token") do
      {:ok,
       %{
         sub: "11111111-1111-1111-1111-111111111111",
         email: "user@example.com",
         roles: [],
         raw: %{}
       }}
    end

    def verify("other-user-token") do
      {:ok,
       %{
         sub: "22222222-2222-2222-2222-222222222222",
         email: "other@example.com",
         roles: [],
         raw: %{}
       }}
    end

    # Expired Supabase JWTs are rejected by the real verifier with an expired
    # reason; exercise that path here.
    def verify("expired-token"), do: {:error, :expired}

    # Any verifier-internal error (e.g. Supabase JWKS fetch failure) surfaces as
    # an opaque term; connect/3 must reject without exposing it to the client.
    def verify("verifier-error-token"), do: {:error, {:verifier, :boom}}

    def verify(_token), do: {:error, :invalid_token}
  end

  setup do
    original = Application.get_env(:dhc, :auth_verifier)
    Application.put_env(:dhc, :auth_verifier, Verifier)
    on_exit(fn -> Application.put_env(:dhc, :auth_verifier, original) end)
    :ok
  end

  describe "connect/3 authentication" do
    test "a valid Supabase access token authenticates the socket and assigns the verified sub" do
      assert {:ok, socket} =
               connect(DhcWeb.UserSocket, %{}, connect_info: %{auth_token: "valid-token"})

      assert socket.assigns.current_user.sub == @user_id
      assert socket.assigns.current_user.email == "user@example.com"
    end

    test "the socket id is scoped to the verified user as users_socket:<sub>" do
      assert {:ok, socket} =
               connect(DhcWeb.UserSocket, %{}, connect_info: %{auth_token: "valid-token"})

      assert socket.id == "users_socket:#{@user_id}"
    end

    test "missing auth_token rejects the connection" do
      assert :error = connect(DhcWeb.UserSocket, %{}, connect_info: %{})
    end

    test "empty auth_token rejects the connection" do
      assert :error = connect(DhcWeb.UserSocket, %{}, connect_info: %{auth_token: ""})
    end

    test "nil auth_token rejects the connection" do
      assert :error = connect(DhcWeb.UserSocket, %{}, connect_info: %{auth_token: nil})
    end

    test "an invalid token is rejected" do
      assert :error =
               connect(DhcWeb.UserSocket, %{}, connect_info: %{auth_token: "not-a-valid-token"})
    end

    test "an expired token is rejected" do
      assert :error =
               connect(DhcWeb.UserSocket, %{}, connect_info: %{auth_token: "expired-token"})
    end

    test "a verifier error rejects the connection without exposing sensitive details" do
      # connect/3 returns :error (never the verifier's opaque reason), so the
      # client learns only that the connection was rejected.
      assert :error =
               connect(DhcWeb.UserSocket, %{},
                 connect_info: %{auth_token: "verifier-error-token"}
               )
    end
  end

  describe "connect/3 assigns a distinct user per token" do
    test "the other-user token assigns the other user's sub and id" do
      assert {:ok, socket} =
               connect(DhcWeb.UserSocket, %{}, connect_info: %{auth_token: "other-user-token"})

      assert socket.assigns.current_user.sub == @other_user_id
      assert socket.id == "users_socket:#{@other_user_id}"
    end
  end

  # ── ALE-164: Phoenix socket token path ────────────────────────────────
  #
  # The dashboard browser exchanges the `_dhc_session` cookie for a short-
  # lived, JS-readable socket token (GET /api/auth/socket-token) and passes it
  # as the `authToken` subprotocol. `connect/3` must accept it in addition to
  # the Supabase JWT, verify it through `Dhc.Auth.get_principal_by_socket_token/1`,
  # and assign the principal as `current_user` with the same shape the JWT path
  # produces (`sub`, `email`, `roles`, `raw`).

  describe "connect/3 Phoenix socket token path (ALE-164)" do
    setup do
      auth_user_id = Ecto.UUID.generate()
      email = "socket-#{System.unique_integer([:positive])}@example.com"

      Dhc.MemberFixtures.member_fixture(%{
        auth_user_id: auth_user_id,
        is_active: true,
        email: email
      })

      Repo.insert_all("user_roles", [[user_id: Ecto.UUID.dump!(auth_user_id), role: "member"]])

      principal = principal_fixture(id: auth_user_id, email: email)
      {:ok, token} = Dhc.Auth.create_socket_token(principal)
      encoded = Base.url_encode64(token, padding: false)

      {:ok, principal: principal, encoded: encoded}
    end

    test "a valid socket token authenticates the socket and assigns the principal", %{
      principal: principal,
      encoded: encoded
    } do
      assert {:ok, socket} =
               connect(DhcWeb.UserSocket, %{}, connect_info: %{auth_token: encoded})

      assert socket.assigns.current_user.sub == principal.id
      assert socket.assigns.current_user.email == principal.email
      assert "member" in socket.assigns.current_user.roles
      assert socket.id == "users_socket:#{principal.id}"
    end

    test "an expired socket token is rejected", %{principal: principal} do
      {:ok, token} = Dhc.Auth.create_socket_token(principal)
      encoded = Base.url_encode64(token, padding: false)

      # Age the row beyond the socket validity window.
      age_token(:crypto.hash(:sha256, token), -2, :minute)

      assert :error = connect(DhcWeb.UserSocket, %{}, connect_info: %{auth_token: encoded})
    end

    test "a garbage authToken that does not decode is rejected" do
      assert :error =
               connect(DhcWeb.UserSocket, %{}, connect_info: %{auth_token: "not-base64-or-real"})
    end
  end
end
