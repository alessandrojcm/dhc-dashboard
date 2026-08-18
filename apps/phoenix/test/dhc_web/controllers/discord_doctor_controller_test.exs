defmodule DhcWeb.DiscordDoctorControllerTest do
  use DhcWeb.ConnCase, async: false

  alias Dhc.Auth.ExternalIdentity
  alias Dhc.Discord.Adapter.Test, as: DiscordAdapter
  alias Dhc.Discord.GuildMember
  alias Dhc.Discord.JoinGrant
  alias Dhc.Invitations.Invitation
  alias Dhc.Onboarding.InvitationAcceptanceAttempt
  alias Dhc.Onboarding.InvitationAcceptanceDiscordContinuation
  alias Dhc.Repo

  defmodule Verifier do
    for role <- ~w(admin president committee_coordinator member treasurer) do
      def verify(unquote("#{role}-token")) do
        {:ok,
         %{
           sub: Ecto.UUID.generate(),
           email: "#{unquote(role)}@example.com",
           roles: [unquote(role)],
           raw: %{}
         }}
      end
    end

    def verify(_token), do: {:error, :invalid_token}
  end

  setup do
    original_verifier = Application.get_env(:dhc, :auth_verifier)
    original_guild_id = Application.get_env(:dhc, :discord_guild_id)
    Application.put_env(:dhc, :auth_verifier, Verifier)
    Application.put_env(:dhc, :discord_guild_id, "guild-123")

    start_supervised!({DiscordAdapter, owner: self()})
    :ok = Dhc.Discord.GuildMemberCache.clear()

    on_exit(fn ->
      Application.put_env(:dhc, :auth_verifier, original_verifier)

      if original_guild_id do
        Application.put_env(:dhc, :discord_guild_id, original_guild_id)
      else
        Application.delete_env(:dhc, :discord_guild_id)
      end
    end)

    :ok
  end

  test "returns the complete empty report to each Discord Doctor role", %{conn: _conn} do
    for role <- ~w(admin president committee_coordinator) do
      DiscordAdapter.script(:list_guild_members, [{:ok, []}])

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{role}-token")
        |> get("/api/discord-doctor/report", refresh: "true")

      assert %{
               "data" => %{
                 "serverMembers" => %{
                   "linkedActive" => [],
                   "linkedInactive" => [],
                   "pendingLink" => [],
                   "unrecognized" => []
                 },
                 "missingMembers" => [],
                 "cache" => %{"fetchedAt" => fetched_at, "ttlSeconds" => 60}
               }
             } = json_response(conn, 200)

      assert {:ok, _, _} = DateTime.from_iso8601(fetched_at)
    end
  end

  test "refuses every role outside the Discord Doctor allowlist", %{conn: conn} do
    for role <- ~w(member treasurer) do
      response =
        conn
        |> recycle()
        |> put_req_header("authorization", "Bearer #{role}-token")
        |> get("/api/discord-doctor/report")

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(response, 403)
    end
  end

  test "classifies every human account once and exposes member safety state", %{conn: conn} do
    active = member("Active", "Linked", is_active: true)

    paused =
      member("Paused", "Protected",
        subscription_paused_until: DateTime.add(DateTime.utc_now(), 7, :day)
      )

    inactive = member("Inactive", "Linked", is_active: false)
    pending = member("Pending", "Believed", is_active: false)
    retired = member("Retired", "Identity")

    link(active, "discord-active")
    link(paused, "discord-paused")
    link(inactive, "discord-inactive")
    link(retired, "discord-retired", retired_at: DateTime.utc_now())
    role(paused, "coach")
    Dhc.DiscordAssignmentFixtures.assignment_fixture(pending.principal_id, "discord-pending")

    DiscordAdapter.script(:list_guild_members, [
      {:ok,
       [
         guild_member("discord-active", "active"),
         guild_member("discord-paused", "paused"),
         guild_member("discord-inactive", "inactive"),
         guild_member("discord-pending", "pending"),
         guild_member("discord-retired", "retired"),
         guild_member("discord-unknown", "unknown"),
         guild_member("discord-bot", "bot", bot: true)
       ]}
    ])

    response = get_report(conn, refresh: true)

    assert %{"data" => %{"serverMembers" => buckets}} = json_response(response, 200)

    assert %{
             "membershipStatus" => "active",
             "kickable" => false,
             "protected" => false
           } = Enum.find(buckets["linkedActive"], &(&1["discordUserId"] == "discord-active"))

    assert %{
             "membershipStatus" => "paused",
             "protected" => true,
             "kickable" => false
           } = Enum.find(buckets["linkedActive"], &(&1["discordUserId"] == "discord-paused"))

    assert [%{"discordUserId" => "discord-inactive", "kickable" => true}] =
             buckets["linkedInactive"]

    assert [pending_row] = buckets["pendingLink"]
    assert pending_row["discordUserId"] == "discord-pending"
    assert pending_row["member"]["firstName"] == "Pending"
    assert pending_row["membershipStatus"] == "inactive"

    assert Enum.map(buckets["unrecognized"], & &1["discordUserId"]) ==
             ~w(discord-retired discord-unknown)

    refute inspect(buckets) =~ "discord-bot"

    all_ids =
      buckets
      |> Map.values()
      |> List.flatten()
      |> Enum.map(& &1["discordUserId"])

    assert length(all_ids) == length(Enum.uniq(all_ids))
  end

  test "reports linked, pending, and never-linked Members missing from the server", %{conn: conn} do
    linked = member("Missing", "Linked")
    pending = member("Missing", "Pending")
    never_linked = member("Never", "Linked")
    present = member("Present", "Linked")

    link(linked, "missing-linked")
    link(present, "present-linked")
    Dhc.DiscordAssignmentFixtures.assignment_fixture(pending.principal_id, "missing-pending")
    pending_join_grant(never_linked.principal_id)

    DiscordAdapter.script(:list_guild_members, [
      {:ok, [guild_member("present-linked", "present")]}
    ])

    response = get_report(conn, refresh: true)

    assert %{"data" => %{"missingMembers" => rows}} = json_response(response, 200)
    by_name = Map.new(rows, &{{&1["member"]["firstName"], &1["member"]["lastName"]}, &1})

    assert Enum.any?(rows, fn row ->
             row["member"]["lastName"] == "Linked" and row["linkStatus"] == "linked" and
               row["discordUserId"] == "missing-linked"
           end)

    assert Enum.any?(rows, fn row ->
             row["member"]["lastName"] == "Pending" and row["linkStatus"] == "pending" and
               row["discordUserId"] == "missing-pending"
           end)

    assert %{"linkStatus" => "never_linked", "autoJoinPending" => true, "discordUserId" => nil} =
             by_name[{"Never", "Linked"}]

    refute Enum.any?(rows, &(&1["member"]["firstName"] == "Present"))
  end

  test "uses the cached member list within the TTL and refresh bypasses it", %{conn: conn} do
    DiscordAdapter.script(:list_guild_members, [
      {:ok, [guild_member("first", "first")]},
      {:ok, [guild_member("refreshed", "refreshed")]}
    ])

    first = get_report(conn)
    assert_receive {:list_guild_members, ["guild-123"]}
    assert server_ids(first) == ["first"]

    cached = get_report(recycle(conn))
    refute_receive {:list_guild_members, ["guild-123"]}
    assert server_ids(cached) == ["first"]

    refreshed = get_report(recycle(conn), refresh: true)
    assert_receive {:list_guild_members, ["guild-123"]}
    assert server_ids(refreshed) == ["refreshed"]
  end

  defp get_report(conn, options \\ []) do
    params = if Keyword.get(options, :refresh, false), do: [refresh: "true"], else: []

    conn
    |> put_req_header("authorization", "Bearer admin-token")
    |> get("/api/discord-doctor/report", params)
  end

  defp server_ids(conn) do
    conn
    |> json_response(200)
    |> get_in(["data", "serverMembers"])
    |> Map.values()
    |> List.flatten()
    |> Enum.map(& &1["discordUserId"])
  end

  defp member(first_name, last_name, attrs \\ []) do
    Dhc.MemberFixtures.member_fixture(
      attrs
      |> Enum.into(%{})
      |> Map.merge(%{first_name: first_name, last_name: last_name})
    )
  end

  defp link(member, subject, attrs \\ []) do
    %ExternalIdentity{
      principal_id: member.principal_id,
      provider: "discord",
      provider_subject: subject,
      metadata: %{},
      retired_at: attrs[:retired_at]
    }
    |> Repo.insert!()
  end

  defp role(member, role) do
    Repo.insert_all("user_roles", [
      [principal_id: Ecto.UUID.dump!(member.principal_id), role: role]
    ])
  end

  defp guild_member(user_id, username, attrs \\ []) do
    %GuildMember{
      user_id: user_id,
      username: username,
      display_name: String.capitalize(username),
      bot: Keyword.get(attrs, :bot, false),
      roles: []
    }
  end

  defp pending_join_grant(principal_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    invitation =
      %Invitation{
        email: "grant-#{System.unique_integer([:positive])}@example.com",
        prospective_principal_id: principal_id,
        status: "accepted",
        expires_at: DateTime.add(now, 7, :day),
        invitation_type: "member",
        first_name: "Never",
        last_name: "Linked",
        phone_number: "+353810000001",
        date_of_birth: ~D[1990-01-01]
      }
      |> Repo.insert!()

    attempt =
      %InvitationAcceptanceAttempt{
        invitation_id: invitation.id,
        status: "completed",
        acceptance_data: %{},
        stripe_state: %{},
        concluded_at: now
      }
      |> Repo.insert!()

    continuation =
      %InvitationAcceptanceDiscordContinuation{
        invitation_id: invitation.id,
        attempt_id: attempt.id,
        status: "consumed",
        expires_at: DateTime.add(now, 7, :day),
        concluded_at: now,
        subject_fingerprint: "test-fingerprint",
        display_metadata: %{}
      }
      |> Repo.insert!()

    %JoinGrant{
      continuation_id: continuation.id,
      attempt_id: attempt.id,
      encrypted_access_token: "encrypted-token",
      expires_at: DateTime.add(now, 7, :day)
    }
    |> Repo.insert!()
  end
end
