defmodule Dhc.Discord.Workers.GuildJoinWorkerTest do
  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  alias Dhc.Discord.Adapter.Test, as: TestAdapter
  alias Dhc.Discord.ApiError
  alias Dhc.Discord.JoinGrant
  alias Dhc.Discord.Workers.GuildJoinWorker
  alias Dhc.Discord.Workers.JoinGrantCleanupWorker
  alias Dhc.Invitations.Invitation
  alias Dhc.Onboarding

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
  end

  test "transient Discord failures stay retryable and retain the grant" do
    {grant, _discord_user_id} = accept_member_with_grant!()
    error = %ApiError{status: 503, message: "Discord unavailable"}
    TestAdapter.script(:add_guild_member, [{:error, error}])

    assert {:error, ^error} = perform_job(GuildJoinWorker, %{"grant_id" => grant.id})
    refute Repo.get!(JoinGrant, grant.id).encrypted_access_token == nil
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

    {:ok, started} =
      Onboarding.start_acceptance(
        invitation.id,
        invitation.email,
        Date.to_iso8601(invitation.date_of_birth)
      )

    {:ok, _state} =
      Onboarding.verify_discord(
        started.continuation_id,
        %{"sub" => discord_user_id, "preferred_username" => "new-member"},
        %{"access_token" => "short-lived-access-token", "expires_in" => 604_800}
      )

    {:ok, %{state: "paymentReady"}} = Onboarding.continue_acceptance(started.continuation_id)

    {:ok, %{state: "accepted"}} =
      Onboarding.submit_payment(started.continuation_id, %{
        next_of_kin_name: "Grace Hopper",
        next_of_kin_phone: "+353810000099",
        confirmation_token: "ctok_guild_join"
      })

    {Repo.get_by!(JoinGrant, continuation_id: started.continuation_id), discord_user_id}
  end

  defp restore_env(key, nil), do: Application.delete_env(:dhc, key)
  defp restore_env(key, value), do: Application.put_env(:dhc, key, value)
end
