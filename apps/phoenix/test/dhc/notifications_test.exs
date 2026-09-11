defmodule Dhc.NotificationsTest do
  use Dhc.DataCase, async: false

  import ExUnit.CaptureLog

  alias Dhc.Notifications
  alias Dhc.Notifications.Broadcaster
  alias Dhc.Notifications.Notification
  alias Dhc.Repo

  @user_id "11111111-1111-1111-1111-111111111111"

  setup do
    Dhc.AuthFixtures.principal_fixture(%{id: @user_id})
    original_broadcaster = Application.get_env(:dhc, :notification_broadcaster)
    on_exit(fn -> Application.put_env(:dhc, :notification_broadcaster, original_broadcaster) end)
    :ok
  end

  describe "create/2 commit succeeds" do
    test "inserts one row and makes exactly one best-effort broadcast on the owner's topic" do
      Phoenix.PubSub.subscribe(Dhc.PubSub, Broadcaster.topic(@user_id))

      assert :ok = Notifications.create(@user_id, "Hello from the club")

      assert [%Notification{principal_id: @user_id, body: "Hello from the club"}] =
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
      assert [%Notification{principal_id: @user_id, body: "committed despite broadcast"}] =
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
      assert [_, _] = rows
      bodies = Enum.map(rows, & &1.body) |> Enum.sort()
      assert bodies == ["first", "second"]

      # Two distinct broadcast attempts — no accidental deduplication.
      assert_received %Phoenix.Socket.Broadcast{event: "notification_created", payload: %{}}
      assert_received %Phoenix.Socket.Broadcast{event: "notification_created", payload: %{}}
      refute_received %Phoenix.Socket.Broadcast{event: "notification_created"}
    end
  end

  describe "mark_read/2 timestamps" do
    test "marks a just-created notification read without violating the date constraint" do
      assert :ok = Notifications.create(@user_id, "read me immediately")
      [%Notification{id: id}] = Repo.all(Notification)

      # Regression: `created_at` defaults to Postgres `NOW()` with microsecond
      # precision, while `read_at` used to be an Elixir `utc_now/0` truncated
      # *down* to the second. Reading a notification in the second it was
      # created therefore produced read_at < created_at and raised
      # Ecto.ConstraintError on `notifications_read_after_created_check` — a 500
      # on the newest notification, which is exactly the one a member taps.
      assert {:ok, %Notification{read_at: %DateTime{} = read_at}} =
               Notifications.mark_read(@user_id, id)

      assert DateTime.compare(read_at, Repo.get!(Notification, id).created_at) != :lt
    end

    test "re-reading keeps the original timestamp" do
      assert :ok = Notifications.create(@user_id, "read twice")
      [%Notification{id: id}] = Repo.all(Notification)

      assert {:ok, %Notification{read_at: first}} = Notifications.mark_read(@user_id, id)
      assert {:ok, %Notification{read_at: second}} = Notifications.mark_read(@user_id, id)

      # When the recipient saw it is a fact, not something a repeated tap moves.
      assert first == second
    end

    test "marking all read clamps to each row's creation time" do
      assert :ok = Notifications.create(@user_id, "one")
      assert :ok = Notifications.create(@user_id, "two")

      assert {:ok, 2} = Notifications.mark_all_read(@user_id)

      for %Notification{created_at: created_at, read_at: read_at} <- Repo.all(Notification) do
        assert %DateTime{} = read_at
        assert DateTime.compare(read_at, created_at) != :lt
      end
    end
  end

  # ── Keyed creation (ALE-287) ────────────────────────────────────

  describe "create_keyed/3 first call" do
    test "creates the row, broadcasts once, and reports itself as the creator" do
      Phoenix.PubSub.subscribe(Dhc.PubSub, Broadcaster.topic(@user_id))

      assert {:ok, :created} = Notifications.create_keyed(@user_id, "loan:1:overdue", "Overdue")

      assert [%Notification{body: "Overdue", notification_key: "loan:1:overdue"}] =
               Repo.all(Notification)

      assert_received %Phoenix.Socket.Broadcast{event: "notification_created", payload: %{}}
      refute_received %Phoenix.Socket.Broadcast{event: "notification_created"}
    end
  end

  describe "create_keyed/3 repeated with the same key" do
    test "creates no second row, makes no second broadcast, and is not an error" do
      Phoenix.PubSub.subscribe(Dhc.PubSub, Broadcaster.topic(@user_id))

      assert {:ok, :created} = Notifications.create_keyed(@user_id, "loan:1:overdue", "Overdue")
      assert_received %Phoenix.Socket.Broadcast{event: "notification_created"}

      # A retry is a normal outcome, not a failure: the caller learns it was
      # not the creator, so it can still complete its own work.
      assert {:ok, :already_created} =
               Notifications.create_keyed(@user_id, "loan:1:overdue", "Overdue")

      assert [_only_one] = Repo.all(Notification)

      # No second signal: an idempotent create must not re-ring the recipient's
      # bell, or a retry loop would look like new activity.
      refute_received %Phoenix.Socket.Broadcast{event: "notification_created"}
    end

    test "a duplicate key does not overwrite the original body or read state" do
      assert {:ok, :created} = Notifications.create_keyed(@user_id, "loan:1:overdue", "first")

      [%Notification{id: id}] = Repo.all(Notification)
      assert {:ok, _} = Notifications.mark_read(@user_id, id)

      assert {:ok, :already_created} =
               Notifications.create_keyed(@user_id, "loan:1:overdue", "second")

      # The row is a fact the recipient has already acted on. An upsert that
      # replaced the body or cleared read_at would resurrect a handled
      # notification, which is exactly the duplicate the key exists to prevent.
      assert [%Notification{body: "first", read_at: %DateTime{}}] = Repo.all(Notification)
    end
  end

  describe "create_keyed/3 key scope" do
    test "the same key for two recipients creates one row each" do
      other = Ecto.UUID.generate()
      Dhc.AuthFixtures.principal_fixture(%{id: other})

      assert {:ok, :created} = Notifications.create_keyed(@user_id, "loan:1:overdue", "Overdue")
      assert {:ok, :created} = Notifications.create_keyed(other, "loan:1:overdue", "Overdue")

      # One logical event notifies a borrower and every operator, so the
      # recipient is part of the uniqueness scope rather than the key string.
      assert [_, _] = Repo.all(Notification)
    end

    test "different keys for one recipient create separate rows" do
      assert {:ok, :created} = Notifications.create_keyed(@user_id, "loan:1:pre_due", "Due soon")
      assert {:ok, :created} = Notifications.create_keyed(@user_id, "loan:1:overdue", "Overdue")

      assert [_, _] = Repo.all(Notification)
    end

    test "an unkeyed notification never collides with another unkeyed one" do
      # The uniqueness index is partial, so the existing unkeyed callers keep
      # their at-least-once behaviour instead of silently deduplicating.
      assert :ok = Notifications.create(@user_id, "same body")
      assert :ok = Notifications.create(@user_id, "same body")

      assert [_, _] = Repo.all(Notification)
    end
  end

  describe "create_keyed/3 rejections" do
    test "refuses to run inside a caller's transaction" do
      result =
        Repo.transact(fn ->
          Notifications.create_keyed(@user_id, "loan:1:overdue", "no row please")
        end)

      # Same rule as create/2: a post-commit broadcast cannot fire from inside
      # a transaction that may still roll back.
      assert {:error, :notification_create_inside_transaction} = result
      assert [] = Repo.all(Notification)
    end

    test "rejects a blank key rather than writing an unkeyed row" do
      # Silently degrading to unkeyed would remove the idempotency the caller
      # asked for at exactly the moment it is needed.
      assert {:error, :invalid_notification_key} =
               Notifications.create_keyed(@user_id, "   ", "body")

      assert [] = Repo.all(Notification)
    end

    test "reports an invalid recipient as an error and writes nothing" do
      assert {:error, %Ecto.Changeset{}} =
               Notifications.create_keyed("not-a-uuid", "loan:1:overdue", "body")

      assert [] = Repo.all(Notification)
    end
  end

  describe "create_keyed/3 broadcast failure" do
    test "keeps the committed row and still reports :created" do
      Application.put_env(:dhc, :notification_broadcaster, __MODULE__.FailingBroadcaster)

      logs =
        capture_log(fn ->
          assert {:ok, :created} =
                   Notifications.create_keyed(@user_id, "loan:1:overdue", "committed")
        end)

      # The row is durable and the key is claimed, so a retry after a failed
      # broadcast must not create a second row — the signal is best-effort,
      # the row is the fact.
      assert [%Notification{body: "committed"}] = Repo.all(Notification)
      assert logs =~ "[notifications] Broadcast failed"

      assert {:ok, :already_created} =
               Notifications.create_keyed(@user_id, "loan:1:overdue", "committed")

      assert [_only_one] = Repo.all(Notification)
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
