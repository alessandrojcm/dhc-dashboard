defmodule Dhc.Notifications.WebPushTest do
  @moduledoc """
  ALE-299: the Web Push channel behind the notification centre.

  Covers the two things that make push a *channel* and not a source of truth:
  subscriptions are per browser installation (the endpoint is the identity,
  and a re-registration reassigns rather than stacks), and delivery is
  best-effort after the notification row exists (a dead endpoint is removed, a
  transient failure is counted and never raised into the creator).
  """

  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  import ExUnit.CaptureLog

  alias Dhc.Notifications
  alias Dhc.Notifications.Notification
  alias Dhc.Notifications.PushSubscription
  alias Dhc.Notifications.WebPush
  alias Dhc.Notifications.Workers.WebPushWorker
  alias Dhc.Repo

  @member_id "11111111-1111-1111-1111-111111111111"
  @other_member_id "22222222-2222-2222-2222-222222222222"

  defmodule RecordingSender do
    @moduledoc false
    @behaviour Dhc.Notifications.WebPush.Sender

    # Records every push to the test process and answers with the outcome
    # configured per endpoint (`:ok` by default; `:raise` raises, to prove a
    # misbehaving sender is contained).
    @impl true
    def push(%PushSubscription{} = subscription, payload) do
      test_pid = Application.fetch_env!(:dhc, :web_push_test_pid)
      send(test_pid, {:web_push_sent, subscription.endpoint, payload})

      :dhc
      |> Application.get_env(:web_push_test_outcomes, %{})
      |> Map.get(subscription.endpoint, :ok)
      |> case do
        :raise -> raise "push exploded"
        outcome -> outcome
      end
    end
  end

  setup do
    Dhc.AuthFixtures.principal_fixture(%{id: @member_id})
    Dhc.AuthFixtures.principal_fixture(%{id: @other_member_id})

    original_sender = Application.get_env(:dhc, :web_push_sender)
    original_vapid = Application.get_env(:web_push_ex, :vapid)
    Application.put_env(:dhc, :web_push_sender, RecordingSender)
    Application.put_env(:dhc, :web_push_test_pid, self())
    Application.put_env(:dhc, :web_push_test_outcomes, %{})

    on_exit(fn ->
      Application.put_env(:dhc, :web_push_sender, original_sender)
      Application.put_env(:web_push_ex, :vapid, original_vapid)
      Application.delete_env(:dhc, :web_push_test_pid)
      Application.delete_env(:dhc, :web_push_test_outcomes)
    end)

    :ok
  end

  describe "configuration" do
    test "is enabled and exposes only the VAPID public key when keys are configured" do
      assert WebPush.enabled?()
      assert WebPush.vapid_public_key() == Application.get_env(:web_push_ex, :vapid)[:public_key]
    end

    test "is disabled with no public key when VAPID is not configured" do
      Application.delete_env(:web_push_ex, :vapid)

      refute WebPush.enabled?()
      assert WebPush.vapid_public_key() == nil
    end
  end

  describe "subscribe/2" do
    test "stores one subscription per browser installation bound to the principal" do
      attrs = subscription_attrs("https://push.example/one")

      assert {:ok, %PushSubscription{} = subscription} = WebPush.subscribe(@member_id, attrs)

      assert subscription.principal_id == @member_id
      assert subscription.endpoint == "https://push.example/one"
      assert subscription.user_agent == "Test UA"
      assert [%PushSubscription{id: id}] = Repo.all(PushSubscription)
      assert id == subscription.id
    end

    test "two browsers of the same member are two independent subscriptions" do
      {:ok, one} = WebPush.subscribe(@member_id, subscription_attrs("https://push.example/one"))
      {:ok, two} = WebPush.subscribe(@member_id, subscription_attrs("https://push.example/two"))

      assert one.id != two.id
      assert [_, _] = WebPush.list_for_principal(@member_id)
    end

    test "re-registering the same endpoint refreshes the keys instead of adding a row" do
      {:ok, first} = WebPush.subscribe(@member_id, subscription_attrs("https://push.example/one"))

      refreshed = subscription_attrs("https://push.example/one")
      {:ok, second} = WebPush.subscribe(@member_id, refreshed)

      assert second.id == first.id
      assert [%PushSubscription{p256dh: p256dh, auth: auth}] = Repo.all(PushSubscription)
      assert p256dh == refreshed.p256dh
      assert auth == refreshed.auth
    end

    test "the same endpoint registered by another principal is reassigned to them" do
      {:ok, _} = WebPush.subscribe(@member_id, subscription_attrs("https://push.example/shared"))

      {:ok, reassigned} =
        WebPush.subscribe(@other_member_id, subscription_attrs("https://push.example/shared"))

      assert reassigned.principal_id == @other_member_id
      assert [%PushSubscription{principal_id: @other_member_id}] = Repo.all(PushSubscription)
      assert WebPush.list_for_principal(@member_id) == []
    end

    test "rejects a non-https endpoint and malformed keys" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               WebPush.subscribe(@member_id, subscription_attrs("http://push.example/plain"))

      assert %{endpoint: _} = errors_on(changeset)

      assert {:error, %Ecto.Changeset{} = changeset} =
               WebPush.subscribe(
                 @member_id,
                 %{
                   subscription_attrs("https://push.example/one")
                   | p256dh: "not-a-key",
                     auth: "x"
                 }
               )

      assert %{p256dh: _, auth: _} = errors_on(changeset)
      assert Repo.all(PushSubscription) == []
    end

    test "rejects endpoints that are not a public push service" do
      for endpoint <- [
            "https://127.0.0.1/push",
            "https://[::1]/push",
            "https://10.0.0.5:8443/push",
            "https://localhost/push",
            "https://phoenix/push",
            "https://db.internal/push",
            "https://printer.local/push",
            "https://user:pw@push.example/push"
          ] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 WebPush.subscribe(@member_id, subscription_attrs(endpoint)),
               endpoint

        assert %{endpoint: _} = errors_on(changeset), endpoint
      end

      assert Repo.all(PushSubscription) == []
    end

    test "rejects a trailing-dot host that would evade the public-hostname checks" do
      # Resolvers treat the trailing root label as the same name, so these must
      # be stripped (then rejected) rather than compared as written.
      for endpoint <- [
            "https://localhost./push",
            "https://127.0.0.1./push",
            "https://db.internal./push"
          ] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 WebPush.subscribe(@member_id, subscription_attrs(endpoint)),
               endpoint

        assert %{endpoint: _} = errors_on(changeset), endpoint
      end

      assert Repo.all(PushSubscription) == []
    end

    test "accepts a public push endpoint after stripping one trailing root dot" do
      assert {:ok, %PushSubscription{endpoint: "https://push.example./one"}} =
               WebPush.subscribe(
                 @member_id,
                 subscription_attrs("https://push.example./one")
               )
    end

    test "rejects an unknown principal without a constraint exception" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               WebPush.subscribe(
                 Ecto.UUID.generate(),
                 subscription_attrs("https://push.example/x")
               )

      assert %{principal_id: _} = errors_on(changeset)
    end
  end

  describe "unsubscribe/2" do
    test "removes the caller's subscription for that endpoint and is idempotent" do
      {:ok, _} = WebPush.subscribe(@member_id, subscription_attrs("https://push.example/one"))

      assert {:ok, :removed} = WebPush.unsubscribe(@member_id, "https://push.example/one")
      assert {:ok, :not_found} = WebPush.unsubscribe(@member_id, "https://push.example/one")
      assert Repo.all(PushSubscription) == []
    end

    test "cannot remove another principal's subscription" do
      {:ok, _} = WebPush.subscribe(@other_member_id, subscription_attrs("https://push.example/o"))

      assert {:ok, :not_found} = WebPush.unsubscribe(@member_id, "https://push.example/o")
      assert [%PushSubscription{}] = Repo.all(PushSubscription)
    end
  end

  describe "deliver/1" do
    test "sends the notification body to every browser of the recipient and nobody else" do
      {:ok, _} = WebPush.subscribe(@member_id, subscription_attrs("https://push.example/a"))
      {:ok, _} = WebPush.subscribe(@member_id, subscription_attrs("https://push.example/b"))
      {:ok, _} = WebPush.subscribe(@other_member_id, subscription_attrs("https://push.example/z"))

      notification = insert_notification(@member_id, "Your loan was approved")

      assert %{sent: 2, removed: 0, failed: 0} = WebPush.deliver(notification)

      assert_received {:web_push_sent, "https://push.example/a", payload}
      assert_received {:web_push_sent, "https://push.example/b", ^payload}
      refute_received {:web_push_sent, "https://push.example/z", _}

      assert payload.body == "Your loan was approved"
      assert payload.tag == notification.id
      assert payload.url == "/dashboard"
    end

    test "removes a subscription the push service reports gone and keeps the rest" do
      {:ok, _} = WebPush.subscribe(@member_id, subscription_attrs("https://push.example/live"))
      {:ok, _} = WebPush.subscribe(@member_id, subscription_attrs("https://push.example/dead"))

      Application.put_env(:dhc, :web_push_test_outcomes, %{
        "https://push.example/dead" => {:error, :gone}
      })

      notification = insert_notification(@member_id, "Reminder")

      assert %{sent: 1, removed: 1, failed: 0} = WebPush.deliver(notification)

      assert [%PushSubscription{endpoint: "https://push.example/live"}] =
               Repo.all(PushSubscription)
    end

    test "a transient failure is counted and logged, the subscription stays, the row stays" do
      {:ok, _} = WebPush.subscribe(@member_id, subscription_attrs("https://push.example/flaky"))

      Application.put_env(:dhc, :web_push_test_outcomes, %{
        "https://push.example/flaky" => {:error, {:push_service, 500}}
      })

      notification = insert_notification(@member_id, "Reminder")

      log =
        capture_log(fn ->
          assert %{sent: 0, removed: 0, failed: 1} = WebPush.deliver(notification)
        end)

      assert log =~ "web-push"
      assert [%PushSubscription{}] = Repo.all(PushSubscription)
      assert [%Notification{}] = Repo.all(Notification)
    end

    test "a sender that raises is a failure, not a crash" do
      {:ok, _} = WebPush.subscribe(@member_id, subscription_attrs("https://push.example/boom"))

      Application.put_env(:dhc, :web_push_test_outcomes, %{
        "https://push.example/boom" => :raise
      })

      notification = insert_notification(@member_id, "Reminder")

      capture_log(fn ->
        assert %{sent: 0, removed: 0, failed: 1} = WebPush.deliver(notification)
      end)
    end

    test "a recipient with no subscriptions is a no-op" do
      notification = insert_notification(@member_id, "Nothing to push")

      assert %{sent: 0, removed: 0, failed: 0} = WebPush.deliver(notification)
      refute_received {:web_push_sent, _, _}
    end
  end

  describe "enqueue_delivery/1" do
    test "enqueues one worker job for the notification when push is configured" do
      notification = insert_notification(@member_id, "Queued")

      assert :ok = WebPush.enqueue_delivery(notification)

      assert_enqueued(worker: WebPushWorker, args: %{notification_id: notification.id})
    end

    test "enqueues nothing when VAPID is not configured" do
      Application.delete_env(:web_push_ex, :vapid)
      notification = insert_notification(@member_id, "Not queued")

      assert :ok = WebPush.enqueue_delivery(notification)

      refute_enqueued(worker: WebPushWorker)
    end
  end

  describe "creation triggers delivery after commit" do
    test "Notifications.create/2 enqueues push delivery for the committed row" do
      assert :ok = Notifications.create(@member_id, "Created")

      assert [%Notification{id: id}] = Repo.all(Notification)
      assert_enqueued(worker: WebPushWorker, args: %{notification_id: id})
    end

    test "Notifications.create_keyed/3 enqueues only for the call that created the row" do
      assert {:ok, :created} = Notifications.create_keyed(@member_id, "event-1", "Keyed")
      assert {:ok, :already_created} = Notifications.create_keyed(@member_id, "event-1", "Keyed")

      assert [%Notification{id: id}] = Repo.all(Notification)
      assert [_one_job] = all_enqueued(worker: WebPushWorker, args: %{notification_id: id})
    end
  end

  describe "WebPushWorker.perform/1" do
    test "delivers to the recipient's browsers" do
      {:ok, _} = WebPush.subscribe(@member_id, subscription_attrs("https://push.example/a"))
      notification = insert_notification(@member_id, "From the worker")

      assert :ok = perform_job(WebPushWorker, %{"notification_id" => notification.id})

      assert_received {:web_push_sent, "https://push.example/a", %{body: "From the worker"}}
    end

    test "a notification that no longer exists cancels the job rather than retrying" do
      assert {:cancel, _reason} =
               perform_job(WebPushWorker, %{"notification_id" => Ecto.UUID.generate()})
    end

    test "a failed browser does not fail the job (no retry can re-push to the healthy ones)" do
      {:ok, _} = WebPush.subscribe(@member_id, subscription_attrs("https://push.example/ok"))
      {:ok, _} = WebPush.subscribe(@member_id, subscription_attrs("https://push.example/bad"))

      Application.put_env(:dhc, :web_push_test_outcomes, %{
        "https://push.example/bad" => {:error, {:push_service, 503}}
      })

      notification = insert_notification(@member_id, "Partial")

      capture_log(fn ->
        assert :ok = perform_job(WebPushWorker, %{"notification_id" => notification.id})
      end)
    end
  end

  defp insert_notification(principal_id, body) do
    :ok = Notifications.create(principal_id, body)
    Repo.one!(from(n in Notification, where: n.body == ^body and n.principal_id == ^principal_id))
  end

  defp subscription_attrs(endpoint) do
    {public, _private} = :crypto.generate_key(:ecdh, :prime256v1)

    %{
      endpoint: endpoint,
      p256dh: Base.url_encode64(public, padding: false),
      auth: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
      user_agent: "Test UA"
    }
  end
end
