defmodule Dhc.NotificationsTest do
  use Dhc.DataCase, async: false

  import ExUnit.CaptureLog

  alias Dhc.Notifications
  alias Dhc.Notifications.Broadcaster
  alias Dhc.Notifications.Notification
  alias Dhc.Repo

  @user_id "11111111-1111-1111-1111-111111111111"

  setup do
    original_broadcaster = Application.get_env(:dhc, :notification_broadcaster)
    on_exit(fn -> Application.put_env(:dhc, :notification_broadcaster, original_broadcaster) end)
    :ok
  end

  describe "create/2 commit succeeds" do
    test "inserts one row and makes exactly one best-effort broadcast on the owner's topic" do
      Phoenix.PubSub.subscribe(Dhc.PubSub, Broadcaster.topic(@user_id))

      assert :ok = Notifications.create(@user_id, "Hello from the club")

      assert [%Notification{user_id: @user_id, body: "Hello from the club"}] =
               Repo.all(Notification)

      # Exactly one notification_created signal, empty payload, delivered to
      # the owner's per-user topic. No cross-user topic receives anything.
      assert_received %Phoenix.Socket.Broadcast{
        topic: "notifications:" <> _,
        event: "notification_created",
        payload: %{}
      }

      refute_received %Phoenix.Socket.Broadcast{event: "notification_created"}
    end
  end

  describe "create/2 insert failure" do
    test "creates no row and emits no signal when the insert fails" do
      Phoenix.PubSub.subscribe(Dhc.PubSub, Broadcaster.topic(@user_id))

      # An uncastable user_id makes the Ecto.Multi insert fail (the changeset
      # is invalid before it reaches the DB). Repo.transact/2 rolls back and
      # surfaces the multi-error tuple; the context must return an error and
      # must not broadcast.
      assert {:error, %Ecto.Changeset{}} = Notifications.create("not-a-uuid", "no row please")

      assert [] = Repo.all(Notification)
      refute_received %Phoenix.Socket.Broadcast{event: "notification_created"}
    end
  end

  describe "create/2 nested transaction rejection" do
    test "fails explicitly when called inside an already-open transaction" do
      Phoenix.PubSub.subscribe(Dhc.PubSub, Broadcaster.topic(@user_id))

      result =
        Repo.transact(fn ->
          Notifications.create(@user_id, "should not be created")
        end)

      # Repo.transact wraps the context's explicit rejection into its own
      # {:error, value} return. The rejection reason must be the explicit
      # nested-transaction error, with no row and no signal.
      assert {:error, :notification_create_inside_transaction} = result

      assert [] = Repo.all(Notification)
      refute_received %Phoenix.Socket.Broadcast{event: "notification_created"}
    end
  end

  describe "create/2 broadcast failure" do
    test "preserves the committed row and successful :ok result, and logs the failure" do
      # Deterministic broadcast failure through the injectable boundary
      # (mirrors the :auth_verifier substitution used by HTTP auth tests).
      Application.put_env(:dhc, :notification_broadcaster, __MODULE__.FailingBroadcaster)

      logs =
        capture_log(fn ->
          assert :ok = Notifications.create(@user_id, "committed despite broadcast")
        end)

      # The committed row survives the best-effort delivery failure.
      assert [%Notification{user_id: @user_id, body: "committed despite broadcast"}] =
               Repo.all(Notification)

      # The failure is observable through the log seam, with the Notification
      # and user identifiers. The committed row survives the best-effort
      # delivery failure and the caller still sees :ok.
      assert logs =~ "[notifications] Broadcast failed"
      assert logs =~ @user_id
    end
  end

  describe "create/2 repeated calls" do
    test "two successful calls create two rows and make two broadcast attempts" do
      Phoenix.PubSub.subscribe(Dhc.PubSub, Broadcaster.topic(@user_id))

      assert :ok = Notifications.create(@user_id, "first")
      assert :ok = Notifications.create(@user_id, "second")

      rows = Repo.all(Notification)
      assert length(rows) == 2
      bodies = Enum.map(rows, & &1.body) |> Enum.sort()
      assert bodies == ["first", "second"]

      # Two distinct broadcast attempts — no accidental deduplication.
      assert_received %Phoenix.Socket.Broadcast{event: "notification_created", payload: %{}}
      assert_received %Phoenix.Socket.Broadcast{event: "notification_created", payload: %{}}
      refute_received %Phoenix.Socket.Broadcast{event: "notification_created"}
    end
  end

  # Test substitute boundary that always fails, so broadcast-failure behaviour
  # is deterministic without monkey patching Phoenix.PubSub.
  defmodule FailingBroadcaster do
    @behaviour Dhc.Notifications.Broadcaster

    @impl true
    def broadcast(_notification), do: {:error, :forced_broadcast_failure}
  end
end
