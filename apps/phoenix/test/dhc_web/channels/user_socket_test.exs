defmodule DhcWeb.UserSocketTest do
  use DhcWeb.ChannelCase, async: false

  import Dhc.AuthFixtures
  import Phoenix.ChannelTest

  alias Dhc.Repo

  describe "connect/3 authentication" do
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
  end

  # ── ALE-164: Phoenix socket token path ────────────────────────────────
  #
  # The dashboard browser exchanges the `_dhc_session` cookie for a short-
  # lived, JS-readable socket token (GET /api/auth/socket-token) and passes it
  # as the `authToken` subprotocol. `connect/3` verifies it through
  # `Dhc.Auth.get_principal_by_socket_token/1` and assigns `current_session`.

  describe "connect/3 Phoenix socket token path (ALE-164)" do
    setup do
      auth_user_id = Ecto.UUID.generate()
      email = "socket-#{System.unique_integer([:positive])}@example.com"

      Dhc.MemberFixtures.member_fixture(%{
        auth_user_id: auth_user_id,
        is_active: true,
        email: email
      })

      Repo.insert_all("user_roles", [
        [principal_id: Ecto.UUID.dump!(auth_user_id), role: "member"]
      ])

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

      assert socket.assigns.current_session.principal.id == principal.id
      assert socket.assigns.current_session.principal.email == principal.email
      assert "member" in socket.assigns.current_session.roles
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
