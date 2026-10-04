defmodule Dhc.Discord.Workers.GuildJoinWorkerTest do
  @moduledoc """
  A denied (401/403) join and an exhausted join are both terminal: the job
  never retries them, so neither produces any Oban signal on its own. These
  tests pin the three signals the worker emits for each — the Sentry capture,
  the structured log, and the keyed member notification.

  The Sentry capture is asserted through the log rather than through an SDK
  stub: the worker calls `Sentry.capture_message/2` directly, like every other
  worker in this app (`docs/agents/notes.md` records the Logger→Sentry
  integration that carries the same fields), and no other worker stubs the SDK
  in tests.
  """

  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  import ExUnit.CaptureLog

  alias Dhc.Discord
  alias Dhc.Discord.Adapter.Test, as: TestAdapter
  alias Dhc.Discord.ApiError
  alias Dhc.Discord.JoinGrant
  alias Dhc.Discord.Workers.GuildJoinWorker
  alias Dhc.Discord.Workers.JoinGrantCleanupWorker
  alias Dhc.Invitations.Invitation
  alias Dhc.Notifications.Notification
  alias Dhc.Onboarding.Acceptance

  setup do
    start_supervised!({TestAdapter, owner: self()})

    original_guild_id = Application.get_env(:dhc, :discord_guild_id)
    original_stripe_adapter = Application.get_env(:dhc, :onboarding_stripe_adapter)
    original_stripe_result = Application.get_env(:dhc, :onboarding_stripe_result)

    Application.put_env(:dhc, :discord_guild_id, "guild-123")
    Application.put_env(:dhc, :onboarding_stripe_adapter, Dhc.Onboarding.StripeAdapter.Test)
    Application.put_env(:dhc, :onboarding_stripe_result, {:ok, %{}})
    Application.put_env(:dhc, :onboarding_test_pid, self())

    on_exit(fn ->
      restore_env(:discord_guild_id, original_guild_id)
      restore_env(:onboarding_stripe_adapter, original_stripe_adapter)
      restore_env(:onboarding_stripe_result, original_stripe_result)
      Application.delete_env(:dhc, :onboarding_test_pid)
    end)

    :ok
  end

  for outcome <- [:added, :already_member] do
    test "#{outcome} zeroizes the grant after adding the accepted member" do
      {grant, discord_user_id} = accept_member_with_grant!()
      TestAdapter.script(:add_guild_member, [{:ok, unquote(outcome)}])

      assert :ok = perform_job(GuildJoinWorker, %{"grant_id" => grant.id})

      assert_receive {:add_guild_member,
                      ["guild-123", ^discord_user_id, "short-lived-access-token", "Ada"]}

      assert Repo.get!(JoinGrant, grant.id).encrypted_access_token == nil
    end
  end

  for status <- [401, 403] do
    test "Discord #{status} zeroizes the grant without retrying" do
      {grant, _discord_user_id} = accept_member_with_grant!()

      TestAdapter.script(:add_guild_member, [
        {:error, %ApiError{status: unquote(status), message: "authorization failed"}}
      ])

      assert :ok = perform_job(GuildJoinWorker, %{"grant_id" => grant.id})
      assert Repo.get!(JoinGrant, grant.id).encrypted_access_token == nil
    end

    test "Discord #{status} denial is observable: log, Sentry fields, member notification" do
      {grant, discord_user_id} = accept_member_with_grant!()

      TestAdapter.script(:add_guild_member, [
        {:error, %ApiError{status: unquote(status), message: "authorization failed"}}
      ])

      logs =
        capture_log(fn ->
          assert :ok = perform_job(GuildJoinWorker, %{"grant_id" => grant.id})
        end)

      # Zeroize semantics are unchanged: the token is unrecoverable.
      assert Repo.get!(JoinGrant, grant.id).encrypted_access_token == nil

      # The log carries the denial at warning level with domain identifiers —
      # the same fields the Sentry capture receives. No token, Discord subject,
      # or contact detail is in either payload.
      assert logs =~ "[guild-join-worker] Discord guild join denied"
      assert logs =~ "[warning]"
      assert logs =~ grant.id
      assert logs =~ grant.attempt_id
      assert logs =~ to_string(unquote(status))
      assert logs =~ "discord_authorization_denied"

      refute logs =~ "short-lived-access-token"
      refute logs =~ discord_user_id

      # The affected member is notified through the keyed seam, so a repeated
      # terminal signal cannot duplicate the row.
      assert {:ok, %{principal_id: principal_id, invitation_id: invitation_id}} =
               Discord.guild_join_context(grant.id)

      assert [
               %Notification{
                 principal_id: ^principal_id,
                 notification_key: key,
                 body: body
               }
             ] = Repo.all(Notification)

      assert key == "discord:guild-join:#{grant.id}:denied"
      assert body =~ "support"

      assert {:ok, %{invitation_id: ^invitation_id}} = Discord.guild_join_context(grant.id)
    end
  end

  test "a repeated run after a denial notifies the member once" do
    {grant, _discord_user_id} = accept_member_with_grant!()

    TestAdapter.script(:add_guild_member, [
      {:error, %ApiError{status: 403, message: "authorization failed"}}
    ])

    assert :ok = perform_job(GuildJoinWorker, %{"grant_id" => grant.id})

    # The grant is now zeroized, so a second run resolves terminal before ever
    # reaching Discord — and must not create a second notification row.
    assert :ok = perform_job(GuildJoinWorker, %{"grant_id" => grant.id})
    assert [_only_one] = Repo.all(Notification)
  end

  test "transient Discord failures stay retryable and retain the grant" do
    {grant, _discord_user_id} = accept_member_with_grant!()
    error = %ApiError{status: 503, message: "Discord unavailable"}
    TestAdapter.script(:add_guild_member, [{:error, error}])

    logs =
      capture_log(fn ->
        assert {:error, ^error} = perform_job(GuildJoinWorker, %{"grant_id" => grant.id})
      end)

    refute Repo.get!(JoinGrant, grant.id).encrypted_access_token == nil

    # Ordinary retries stay quiet: no terminal signal yet, so nothing is logged
    # and the member is not notified before the retries are actually spent.
    refute logs =~ "[guild-join-worker]"
    assert Repo.all(Notification) == []
  end

  test "transient failures signal once on the final attempt" do
    {grant, _discord_user_id} = accept_member_with_grant!()
    error = %ApiError{status: 503, message: "Discord unavailable"}
    TestAdapter.script(:add_guild_member, [{:error, error}])

    logs =
      capture_log(fn ->
        assert {:error, ^error} =
                 perform_job(GuildJoinWorker, %{"grant_id" => grant.id}, attempt: 5)
      end)

    # The grant is retained (Oban owns the discard), but the failure is now
    # visible at error level with domain context.
    refute Repo.get!(JoinGrant, grant.id).encrypted_access_token == nil
    assert logs =~ "[guild-join-worker] Discord guild join retries exhausted"
    assert logs =~ "[error]"
    assert logs =~ grant.id
    assert logs =~ grant.attempt_id
    assert logs =~ "discord_api_error"
    refute logs =~ "short-lived-access-token"

    assert {:ok, %{principal_id: principal_id}} = Discord.guild_join_context(grant.id)

    assert [
             %Notification{
               principal_id: ^principal_id,
               notification_key: key,
               body: body
             }
           ] = Repo.all(Notification)

    assert key == "discord:guild-join:#{grant.id}:exhausted"
    assert body =~ "support"
  end

  test "a repeated final-attempt signal notifies the member once" do
    {grant, _discord_user_id} = accept_member_with_grant!()
    error = %ApiError{status: 503, message: "Discord unavailable"}

    # Two terminal attempts for one grant — a re-executed final attempt, or a
    # manual replay. Each emits its own log and Sentry event, but the keyed
    # seam collapses them into one unread row.
    TestAdapter.script(:add_guild_member, [{:error, error}, {:error, error}])

    logs =
      capture_log(fn ->
        for _attempt <- 1..2 do
          assert {:error, ^error} =
                   perform_job(GuildJoinWorker, %{"grant_id" => grant.id}, attempt: 5)
        end
      end)

    assert [_, _, _] = String.split(logs, "retries exhausted")
    assert [_only_one] = Repo.all(Notification)
  end

  test "cleanup removes expired grants" do
    {expired_grant, _discord_user_id} = accept_member_with_grant!()

    assert :ok = perform_job(JoinGrantCleanupWorker, %{})
    assert Repo.get!(JoinGrant, expired_grant.id).encrypted_access_token

    expired_grant
    |> Ecto.Changeset.change(
      expires_at: DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
    )
    |> Repo.update!()

    assert :ok = perform_job(JoinGrantCleanupWorker, %{})
    refute Repo.get(JoinGrant, expired_grant.id)
  end

  defp accept_member_with_grant! do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    discord_user_id = "discord-user-#{System.unique_integer([:positive])}"

    invitation =
      %Invitation{
        email: "guild-join-#{System.unique_integer([:positive])}@example.com",
        prospective_principal_id: Ecto.UUID.generate(),
        status: "pending",
        expires_at: DateTime.add(now, 7, :day),
        invitation_type: "member",
        first_name: "Ada",
        last_name: "Lovelace",
        phone_number: "+353810000000",
        date_of_birth: ~D[1990-01-01]
      }
      |> Repo.insert!()

    {:ok, handle, _view} =
      Acceptance.open(
        invitation.id,
        invitation.email,
        Date.to_iso8601(invitation.date_of_birth)
      )

    {:ok, _view} =
      Acceptance.verify_discord(
        handle,
        %{"sub" => discord_user_id, "preferred_username" => "new-member"},
        %{"access_token" => "short-lived-access-token", "expires_in" => 604_800}
      )

    {:ok, %{state: "paymentReady"}} = Acceptance.consume_proof(handle)

    {:ok, %{state: "accepted"}} =
      Acceptance.submit_payment(handle, %{
        next_of_kin_name: "Grace Hopper",
        next_of_kin_phone: "+353810000099",
        confirmation_token: "ctok_guild_join"
      })

    {Repo.get_by!(JoinGrant, continuation_id: handle), discord_user_id}
  end

  defp restore_env(key, nil), do: Application.delete_env(:dhc, key)
  defp restore_env(key, value), do: Application.put_env(:dhc, key, value)
end
