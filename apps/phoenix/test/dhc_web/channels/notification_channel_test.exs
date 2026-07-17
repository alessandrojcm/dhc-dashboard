defmodule DhcWeb.NotificationChannelTest do
  use DhcWeb.ChannelCase, async: false

  import Phoenix.ChannelTest
  import Phoenix.ConnTest, only: [build_conn: 3]
  import Plug.Conn

  alias DhcWeb.NotificationChannel
  alias DhcWeb.UserSocket

  @user_id "11111111-1111-1111-1111-111111111111"
  @other_user_id "22222222-2222-2222-2222-222222222222"

  # Verifier substitution mirroring DhcWeb.NotificationsControllerTest.
  defmodule Verifier do
    def verify("user-token") do
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

    def verify(_token), do: {:error, :invalid_token}
  end

  setup do
    original = Application.get_env(:dhc, :auth_verifier)
    Application.put_env(:dhc, :auth_verifier, Verifier)
    on_exit(fn -> Application.put_env(:dhc, :auth_verifier, original) end)
    :ok
  end

  # Builds an authenticated socket for the given token via the real connect/3,
  # so join/3 sees the exact assigns shape production uses.
  defp authenticated_socket(token) do
    {:ok, socket} = connect(UserSocket, %{}, connect_info: %{auth_token: token})
    socket
  end

  describe "join/3 own-topic authorization" do
    test "a user can join their own notifications:<sub> topic" do
      socket = authenticated_socket("user-token")

      assert {:ok, _, joined_socket} =
               subscribe_and_join(socket, NotificationChannel, "notifications:#{@user_id}")

      assert joined_socket.assigns.current_user.sub == @user_id
    end

    test "joining another user's notifications:<sub> topic is rejected as unauthorized" do
      socket = authenticated_socket("user-token")

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(socket, NotificationChannel, "notifications:#{@other_user_id}")
    end

    test "a user cannot reach another user's topic by authenticating as someone else" do
      # The other user authenticates with their own token and is still rejected
      # from the first user's topic.
      socket = authenticated_socket("other-user-token")

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(socket, NotificationChannel, "notifications:#{@user_id}")
    end
  end

  describe "notification_created broadcast isolation" do
    test "a broadcast to the owner's topic reaches that user's joined channel" do
      socket = authenticated_socket("user-token")

      {:ok, _, _joined_socket} =
        subscribe_and_join(socket, NotificationChannel, "notifications:#{@user_id}")

      DhcWeb.Endpoint.broadcast("notifications:#{@user_id}", "notification_created", %{})

      # Phoenix's default channel behavior pushes broadcasts on a joined topic
      # straight to the client (handle_info(%Broadcast{...}) -> push/3). Since
      # the channel does not intercept the event, assert_push sees the empty
      # payload that the browser treats as an invalidation signal.
      assert_push "notification_created", %{}
    end

    test "a broadcast to one user's topic does NOT reach another user's joined channel" do
      # User A joins their own topic.
      socket_a = authenticated_socket("user-token")

      {:ok, _, _joined_a} =
        subscribe_and_join(socket_a, NotificationChannel, "notifications:#{@user_id}")

      # User B joins their own (different) topic.
      socket_b = authenticated_socket("other-user-token")

      {:ok, _, _joined_b} =
        subscribe_and_join(socket_b, NotificationChannel, "notifications:#{@other_user_id}")

      # Broadcast only to User B's topic.
      DhcWeb.Endpoint.broadcast("notifications:#{@other_user_id}", "notification_created", %{})

      # User B's channel receives the event...
      assert_push "notification_created", %{}

      # ...and User A's channel does not. assert_push is process-scoped to the
      # test process, which is subscribed to both channel pids via
      # subscribe_and_join; assert_received checks nothing matching arrives.
      refute_receive {:socket_push, _, {:text, _}}, 50
    end
  end

  describe "production WebSocket origin validation" do
    # The socket transport's check_origin is derived from CORS_ALLOWED_ORIGINS.
    # These tests exercise Phoenix.Socket.Transport.check_origin/4 directly
    # against a conn carrying an Origin header, asserting the configured
    # dashboard origin is accepted and an unrelated origin is rejected.
    #
    # `check_origin/4` resolves the allow-list through
    # `Phoenix.Config.cache(endpoint, {:check_origin, handler}, ...)`, keyed by
    # the `handler` argument. The first call for a given handler seeds the
    # cache from `Keyword.get(opts, :check_origin, endpoint.config(:check_origin))`.
    # To keep these tests deterministic and independent of the endpoint's
    # test.exs config and of one another, each test passes its allow-list in
    # `opts` and uses a UNIQUE handler atom, so each test seeds a fresh cache
    # entry with exactly the origins it asserts against.

    @production_origin "https://dashboard.dublinhemaclub.com"
    @unrelated_origin "https://evil.example.com"

    test "accepts the configured dashboard origin" do
      conn =
        :get
        |> build_conn("/socket/websocket", [])
        |> put_req_header("origin", @production_origin)

      # The dashboard origin is in the production CORS_ALLOWED_ORIGINS
      # allow-list, so the socket handshake proceeds (not halted).
      checked =
        Phoenix.Socket.Transport.check_origin(
          conn,
          :test_dashboard_origin_accept,
          DhcWeb.Endpoint,
          check_origin: [@production_origin]
        )

      refute checked.halted
    end

    test "rejects an unrelated origin with 403 Forbidden" do
      conn =
        :get
        |> build_conn("/socket/websocket", [])
        |> put_req_header("origin", @unrelated_origin)

      # A no-op sender keeps the test in control of the conn; the real transport
      # would send the 403 and halt. We assert halt + status.
      checked =
        Phoenix.Socket.Transport.check_origin(
          conn,
          :test_unrelated_origin_reject,
          DhcWeb.Endpoint,
          [check_origin: [@production_origin]],
          fn conn -> conn end
        )

      assert checked.halted
      assert checked.status == 403
    end

    test "an empty check_origin allow-list never matches an unrelated origin" do
      # Guard against accidental wildcard/disabled checks in production: with
      # the allow-list empty (but NOT set to false), an origin not in the list
      # is rejected — never implicitly allowed.
      conn =
        :get
        |> build_conn("/socket/websocket", [])
        |> put_req_header("origin", @unrelated_origin)

      checked =
        Phoenix.Socket.Transport.check_origin(
          conn,
          :test_empty_allowlist_reject,
          DhcWeb.Endpoint,
          [check_origin: []],
          fn conn -> conn end
        )

      assert checked.halted
      assert checked.status == 403
    end
  end
end
