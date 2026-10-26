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

  describe "connect/3 Phoenix socket token path" do
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
      {token, session_token_id} = socket_token(principal)
      encoded = Base.url_encode64(token, padding: false)

      {:ok, principal: principal, encoded: encoded, session_token_id: session_token_id}
    end

    test "a valid socket token authenticates the socket and assigns the principal", %{
      principal: principal,
      encoded: encoded,
      session_token_id: session_token_id
    } do
      assert {:ok, socket} =
               connect(DhcWeb.UserSocket, %{}, connect_info: %{auth_token: encoded})

      assert socket.assigns.current_session.principal.id == principal.id
      assert socket.assigns.current_session.principal.email == principal.email
      assert "member" in socket.assigns.current_session.roles

      assert socket.id ==
               Dhc.Auth.session_socket_topic(principal.id, session_token_id)
    end

    test "an expired socket token is rejected", %{principal: principal} do
      {token, _session_token_id} = socket_token(principal)
      encoded = Base.url_encode64(token, padding: false)

      # Age the row beyond the socket validity window.
      age_token(:crypto.hash(:sha256, token), -2, :minute)

      assert :error = connect(DhcWeb.UserSocket, %{}, connect_info: %{auth_token: encoded})
    end

    test "transport initialization catches revocation between connect and subscription", %{
      principal: principal,
      encoded: encoded
    } do
      %{principal_id: actor_id} = Dhc.MemberFixtures.member_fixture()
      Repo.insert_all(Dhc.Auth.UserRole, [%{principal_id: actor_id, role: "admin"}])

      {:ok, socket} = connect(DhcWeb.UserSocket, %{}, connect_info: %{auth_token: encoded})

      # connect succeeded, but the transport has not subscribed to its socket
      # id yet. It misses this broadcast; init must detect the deleted row.
      assert {:ok, _} =
               Dhc.Auth.Roles.update(actor_id, principal.id, %{
                 "roles" => ["member", "coach"],
                 "expectedRoles" => ["member"]
               })

      assert {:ok, state} = DhcWeb.UserSocket.init({%{}, socket})
      assert_receive disconnect = %Phoenix.Socket.Broadcast{event: "disconnect"}

      assert {:stop, {:shutdown, :disconnected}, 1001, ^state} =
               DhcWeb.UserSocket.handle_info(disconnect, state)

      # Even an inbound join queued before the disconnect cannot be handled.
      assert {:stop, {:shutdown, :disconnected}, 1001, ^state} =
               DhcWeb.UserSocket.handle_in({"queued join", []}, state)
    end

    test "transport initialization retains valid authentication", %{encoded: encoded} do
      {:ok, socket} = connect(DhcWeb.UserSocket, %{}, connect_info: %{auth_token: encoded})
      assert {:ok, {_state, initialized}} = DhcWeb.UserSocket.init({%{}, socket})

      assert initialized.assigns.current_session.principal.id ==
               socket.assigns.current_session.principal.id

      refute Map.get(initialized.assigns, :authentication_revoked, false)
    end

    test "a garbage authToken that does not decode is rejected" do
      assert :error =
               connect(DhcWeb.UserSocket, %{}, connect_info: %{auth_token: "not-base64-or-real"})
    end

    test "deleting the originating session revokes the socket token", %{principal: principal} do
      session = session_token(principal)
      {:ok, token} = Dhc.Auth.create_socket_token(principal, session)
      encoded = Base.url_encode64(token, padding: false)

      assert {:ok, _} = connect(DhcWeb.UserSocket, %{}, connect_info: %{auth_token: encoded})

      assert :ok = Dhc.Auth.delete_session_token(session)

      # The established socket's credential is dead for any new connection.
      assert {:error, :invalid} = Dhc.Auth.get_principal_by_socket_token(token)
      assert :error = connect(DhcWeb.UserSocket, %{}, connect_info: %{auth_token: encoded})
    end

    test "a current-device logout disconnects that session's socket only", %{principal: principal} do
      a_session = session_token(principal)
      {:ok, a_token} = Dhc.Auth.create_socket_token(principal, a_session)
      a_encoded = Base.url_encode64(a_token, padding: false)

      assert {:ok, a_socket} =
               connect(DhcWeb.UserSocket, %{}, connect_info: %{auth_token: a_encoded})

      topic_a = a_socket.id

      # Another device: its own session, its own socket, still signed in.
      b_session = session_token(principal)
      {:ok, b_token} = Dhc.Auth.create_socket_token(principal, b_session)
      b_encoded = Base.url_encode64(b_token, padding: false)

      assert {:ok, b_socket} =
               connect(DhcWeb.UserSocket, %{}, connect_info: %{auth_token: b_encoded})

      topic_b = b_socket.id

      refute topic_a == topic_b
      :ok = DhcWeb.Endpoint.subscribe(topic_a)
      :ok = DhcWeb.Endpoint.subscribe(topic_b)

      # Sign out device A only.
      assert :ok = Dhc.Auth.delete_session_token(a_session)

      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic_a, event: "disconnect"}
      refute_received %Phoenix.Socket.Broadcast{topic: ^topic_b, event: "disconnect"}

      assert {:error, :invalid} = Dhc.Auth.get_principal_by_socket_token(a_token)
      assert {:ok, _, _, _} = Dhc.Auth.get_socket_projection(b_token)
    end
  end
end
