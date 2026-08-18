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
           sub: principal_id(unquote(role)),
           email: "#{unquote(role)}@example.com",
           roles: [unquote(role)],
           raw: %{}
         }}
      end
    end

    def verify(_token), do: {:error, :invalid_token}

    def principal_id("admin"), do: "00000000-0000-0000-0000-000000000001"
    def principal_id("president"), do: "00000000-0000-0000-0000-000000000002"

    def principal_id("committee_coordinator"),
      do: "00000000-0000-0000-0000-000000000003"

    def principal_id("member"), do: "00000000-0000-0000-0000-000000000004"
    def principal_id("treasurer"), do: "00000000-0000-0000-0000-000000000005"
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

  test "kicks an unrecognized account with the authenticated admin in the audit reason", %{
    conn: conn
  } do
    member("Ada", "Admin",
      principal_id: Verifier.principal_id("admin"),
      email: "admin@example.com"
    )

    DiscordAdapter.script(:list_guild_members, [
      {:ok, [guild_member("discord-unknown", "unknown")]}
    ])

    DiscordAdapter.script(:kick_guild_member, [:ok])

    response =
      post_kick(conn, %{
        "discordUserIds" => ["discord-unknown"],
        "note" => "Reviewed with the committee"
      })

    assert %{
             "data" => %{
               "results" => [
                 %{
                   "discordUserId" => "discord-unknown",
                   "outcome" => "kicked",
                   "reason" => nil,
                   "error" => nil
                 }
               ]
             }
           } = json_response(response, 200)

    assert_receive {:kick_guild_member,
                    [
                      "guild-123",
                      "discord-unknown",
                      "DHC Doctor — Ada Admin: unrecognized — Reviewed with the committee"
                    ]}
  end

  test "refuses every unsafe row while continuing a reviewed batch", %{conn: conn} do
    member("Ada", "Admin",
      principal_id: Verifier.principal_id("admin"),
      email: "admin@example.com"
    )

    protected = member("Protected", "Member", is_active: false)

    paused =
      member("Paused", "Member",
        subscription_paused_until: DateTime.add(DateTime.utc_now(), 7, :day)
      )

    pending = member("Pending", "Member", is_active: false)
    active = member("Active", "Member")

    link(protected, "discord-protected")
    role(protected, "coach")
    Dhc.DiscordAssignmentFixtures.assignment_fixture(paused.principal_id, "discord-paused")
    Dhc.DiscordAssignmentFixtures.assignment_fixture(pending.principal_id, "discord-pending")
    link(active, "discord-active")

    DiscordAdapter.script(:list_guild_members, [
      {:ok,
       [
         guild_member("discord-protected", "protected"),
         guild_member("discord-paused", "paused"),
         guild_member("discord-pending", "pending"),
         guild_member("discord-bot", "bot", bot: true),
         guild_member("discord-active", "active"),
         guild_member("discord-unknown", "unknown")
       ]}
    ])

    DiscordAdapter.script(:kick_guild_member, [:ok])

    response =
      post_kick(conn, %{
        "discordUserIds" => [
          "discord-protected",
          "discord-paused",
          "discord-pending",
          "discord-bot",
          "discord-active",
          "discord-unknown"
        ]
      })

    assert %{"data" => %{"results" => results}} = json_response(response, 200)
    by_id = Map.new(results, &{&1["discordUserId"], &1})

    assert %{"outcome" => "refused", "reason" => "protected member"} =
             by_id["discord-protected"]

    assert %{"outcome" => "refused", "reason" => "paused member"} =
             by_id["discord-paused"]

    assert %{
             "outcome" => "refused",
             "reason" => "pending links can only be kicked one at a time"
           } = by_id["discord-pending"]

    assert %{"outcome" => "refused", "reason" => "bot account"} = by_id["discord-bot"]

    assert %{"outcome" => "refused", "reason" => "active linked member"} =
             by_id["discord-active"]

    assert %{"outcome" => "kicked", "reason" => nil, "error" => nil} =
             by_id["discord-unknown"]

    assert_receive {:kick_guild_member,
                    ["guild-123", "discord-unknown", "DHC Doctor — Ada Admin: unrecognized"]}

    refute_receive {:kick_guild_member, _arguments}
  end

  test "returns every Discord kick outcome as row data in one successful response", %{conn: conn} do
    member("Ada", "Admin",
      principal_id: Verifier.principal_id("admin"),
      email: "admin@example.com"
    )

    user_ids = ~w(discord-kicked discord-left discord-forbidden discord-failed)

    DiscordAdapter.script(:list_guild_members, [
      {:ok, Enum.map(user_ids, &guild_member(&1, &1))}
    ])

    DiscordAdapter.script(:kick_guild_member, [
      :ok,
      {:error, %Dhc.Discord.ApiError{status: 404, message: "Unknown Member"}},
      {:error, %Dhc.Discord.ApiError{status: 403, message: "Missing Permissions"}},
      {:error, :timeout}
    ])

    response = post_kick(conn, %{"discordUserIds" => user_ids})

    assert %{"data" => %{"results" => results}} = json_response(response, 200)
    by_id = Map.new(results, &{&1["discordUserId"], &1})

    assert %{"outcome" => "kicked", "error" => nil} = by_id["discord-kicked"]
    assert %{"outcome" => "already_left", "error" => nil} = by_id["discord-left"]

    assert %{"outcome" => "failed", "error" => "Missing Permissions"} =
             by_id["discord-forbidden"]

    assert %{"outcome" => "failed", "error" => "Discord request failed"} =
             by_id["discord-failed"]
  end

  test "allows a pending link to be kicked only as a single reviewed target", %{conn: conn} do
    member("Ada", "Admin",
      principal_id: Verifier.principal_id("admin"),
      email: "admin@example.com"
    )

    pending = member("Pending", "Member", is_active: false)
    Dhc.DiscordAssignmentFixtures.assignment_fixture(pending.principal_id, "discord-pending")

    DiscordAdapter.script(:list_guild_members, [
      {:ok, [guild_member("discord-pending", "pending")]}
    ])

    DiscordAdapter.script(:kick_guild_member, [:ok])

    response = post_kick(conn, %{"discordUserIds" => ["discord-pending"]})

    assert %{
             "data" => %{
               "results" => [
                 %{"discordUserId" => "discord-pending", "outcome" => "kicked"}
               ]
             }
           } = json_response(response, 200)

    assert_receive {:kick_guild_member,
                    ["guild-123", "discord-pending", "DHC Doctor — Ada Admin: pending_link"]}
  end

  test "kicks a linked inactive member with the server-derived bucket in the reason", %{
    conn: conn
  } do
    member("Ada", "Admin",
      principal_id: Verifier.principal_id("admin"),
      email: "admin@example.com"
    )

    inactive = member("Inactive", "Member", is_active: false)
    link(inactive, "discord-inactive")

    DiscordAdapter.script(:list_guild_members, [
      {:ok, [guild_member("discord-inactive", "inactive")]}
    ])

    DiscordAdapter.script(:kick_guild_member, [:ok])

    response = post_kick(conn, %{"discordUserIds" => ["discord-inactive"]})

    assert %{
             "data" => %{
               "results" => [
                 %{"discordUserId" => "discord-inactive", "outcome" => "kicked"}
               ]
             }
           } = json_response(response, 200)

    assert_receive {:kick_guild_member,
                    [
                      "guild-123",
                      "discord-inactive",
                      "DHC Doctor — Ada Admin: linked_inactive"
                    ]}
  end

  test "authorizes only the three Discord Doctor roles for kicks", %{conn: conn} do
    for role <- ~w(admin president committee_coordinator) do
      member(String.capitalize(role), "Admin",
        principal_id: Verifier.principal_id(role),
        email: "#{role}@example.com"
      )

      DiscordAdapter.script(:list_guild_members, [{:ok, []}])

      response =
        conn
        |> recycle()
        |> post_kick(%{"discordUserIds" => ["already-left"]}, role)

      assert %{
               "data" => %{
                 "results" => [
                   %{"discordUserId" => "already-left", "outcome" => "already_left"}
                 ]
               }
             } = json_response(response, 200)
    end

    for role <- ~w(member treasurer) do
      response =
        conn
        |> recycle()
        |> post_kick(%{"discordUserIds" => ["discord-unknown"]}, role)

      assert %{"errors" => %{"detail" => "Insufficient role"}} =
               json_response(response, 403)
    end
  end

  test "rejects kick requests that do not match the OpenAPI contract", %{conn: conn} do
    invalid_requests = [
      {%{}, "At least one Discord user id is required"},
      {%{"discordUserIds" => []}, "At least one Discord user id is required"},
      {%{"discordUserIds" => [""]}, "Discord user ids must be non-empty strings"},
      {%{"discordUserIds" => ["same", "same"]}, "Discord user ids must be unique"},
      {%{"discordUserIds" => ["valid"], "note" => 42}, "Note must be a string"},
      {%{"discordUserIds" => ["valid"], "unexpected" => true},
       "Request contains unsupported fields"}
    ]

    for {request, detail} <- invalid_requests do
      response =
        conn
        |> recycle()
        |> post_kick(request)

      assert %{"errors" => %{"detail" => ^detail}} = json_response(response, 422)
    end

    refute_receive {:list_guild_members, _arguments}
  end

  defp get_report(conn, options \\ []) do
    params = if Keyword.get(options, :refresh, false), do: [refresh: "true"], else: []

    conn
    |> put_req_header("authorization", "Bearer admin-token")
    |> get("/api/discord-doctor/report", params)
  end

  defp post_kick(conn, params, role \\ "admin") do
    conn
    |> put_req_header("authorization", "Bearer #{role}-token")
    |> post("/api/discord-doctor/kick", params)
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
