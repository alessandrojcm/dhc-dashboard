defmodule Dhc.TrainingCalendar.SyncTest do
  use Dhc.DataCase, async: false

  alias Dhc.Auth.Principal
  alias Dhc.Auth.UserRole
  alias Dhc.MemberFixtures
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Members
  alias Dhc.Repo
  alias Dhc.TrainingCalendar
  alias Dhc.TrainingCalendar.Google
  alias Dhc.TrainingCalendar.Grant
  alias Dhc.UserProfiles.UserProfile

  @calendar "training@example.com"

  setup do
    original = Application.fetch_env!(:dhc, TrainingCalendar)

    Application.put_env(:dhc, TrainingCalendar,
      enabled: true,
      calendar_id: @calendar,
      client_id: "training-client",
      client_secret: "training-secret",
      refresh_token: "training-refresh",
      req_options: [plug: {Req.Test, Google}]
    )

    on_exit(fn -> Application.put_env(:dhc, TrainingCalendar, original) end)

    provider =
      start_supervised!({Agent, fn -> %{rules: %{}, writes: [], failures: %{}, revision: 0} end})

    Req.Test.stub(Google, &google(&1, provider))
    %{provider: provider}
  end

  test "the source projection excludes paused/inactive members but includes active coaches" do
    now = ~U[2026-11-06 00:00:00Z]
    member("active@example.com")
    member("paused@example.com", subscription_paused_until: DateTime.add(now, 1))
    member("pause-ended@example.com", subscription_paused_until: now)
    member("inactive@example.com", is_active: false)
    coach = member("coach@example.com", subscription_paused_until: DateTime.add(now, 86_400))
    role(coach, "coach")
    inactive_coach = member("inactive-coach@example.com", is_active: false)
    role(inactive_coach, "coach")
    unpaid_coach = member("unpaid-coach@example.com")
    role(unpaid_coach, "coach")
    Repo.delete!(Repo.get!(MemberProfile, unpaid_coach.principal_id))
    not_member = member("profile-only@example.com")
    Repo.delete!(Repo.get!(MemberProfile, not_member.principal_id))

    assert Members.training_calendar_emails(now) == [
             "active@example.com",
             "coach@example.com",
             "pause-ended@example.com",
             "unpaid-coach@example.com"
           ]
  end

  test "grants readers once and unchanged daily passes make no mutations", %{provider: provider} do
    member("active@example.com")
    coach = member("coach@example.com", subscription_paused_until: tomorrow())
    role(coach, "coach")
    member("paused@example.com", subscription_paused_until: tomorrow())
    member("inactive@example.com", is_active: false)

    assert {:ok, %{added: 2, removed: 0}} = TrainingCalendar.sync()
    assert {:ok, %{added: 0, removed: 0}} = TrainingCalendar.sync()
    assert [_, _] = writes(provider)
    assert Enum.all?(rules(provider), &(&1["role"] == "reader"))
    assert Repo.aggregate(Grant, :count) == 2
  end

  test "revokes managed access after pause, deactivation or lost coaching eligibility", %{
    provider: provider
  } do
    paused = member("paused-later@example.com")
    inactive = member("inactive-later@example.com")
    coach = member("former-coach@example.com", subscription_paused_until: tomorrow())
    role(coach, "coach")
    assert {:ok, %{added: 3}} = TrainingCalendar.sync()

    update_member(paused, subscription_paused_until: tomorrow())
    deactivate(inactive)
    Repo.delete_all(from r in UserRole, where: r.principal_id == ^coach.principal_id)

    assert {:ok, %{added: 0, removed: 3}} = TrainingCalendar.sync()
    assert rules(provider) == []
    assert Repo.aggregate(Grant, :count) == 0
  end

  test "a coach losing the role keeps access when their membership still qualifies", %{
    provider: provider
  } do
    coach = member("coach-member@example.com")
    role(coach, "coach")
    assert {:ok, %{added: 1}} = TrainingCalendar.sync()
    Repo.delete_all(from r in UserRole, where: r.principal_id == ^coach.principal_id)

    assert {:ok, %{added: 0, removed: 0}} = TrainingCalendar.sync()
    assert [_] = rules(provider)
  end

  test "preserves every pre-existing share, including inactive people and owners", %{
    provider: provider
  } do
    member("manual-reader@example.com")
    member("manual-editor@example.com")
    seed_rule(provider, "manual-reader@example.com")
    seed_rule(provider, "manual-editor@example.com", "writer")
    seed_rule(provider, "owner@example.com", "owner")
    seed_rule(provider, "inactive-manual@example.com")

    Agent.update(provider, fn state ->
      group = %{
        "id" => "group:committee",
        "etag" => "group",
        "role" => "reader",
        "scope" => %{"type" => "group", "value" => "committee@example.com"}
      }

      public = %{
        "id" => "default",
        "etag" => "public",
        "role" => "reader",
        "scope" => %{"type" => "default"}
      }

      %{
        state
        | rules: state.rules |> Map.put(group["id"], group) |> Map.put(public["id"], public)
      }
    end)

    assert {:ok, %{added: 0, removed: 0}} = TrainingCalendar.sync()
    assert [_, _, _, _, _, _] = rules(provider)
    assert writes(provider) == []
    assert Repo.aggregate(Grant, :count) == 0
  end

  test "a manually changed managed rule is no longer ours to revoke", %{provider: provider} do
    person = member("promoted@example.com")
    assert {:ok, %{added: 1}} = TrainingCalendar.sync()
    seed_rule(provider, "promoted@example.com", "writer", "manual-edit")
    deactivate(person)

    assert {:ok, %{removed: 0}} = TrainingCalendar.sync()
    assert [%{"role" => "writer"}] = rules(provider)
    assert Repo.aggregate(Grant, :count) == 0
  end

  test "conditional deletion cannot remove a concurrent administrator edit", %{provider: provider} do
    person = member("race@example.com")
    assert {:ok, _} = TrainingCalendar.sync()
    deactivate(person)
    failure(provider, {:delete, "race@example.com"}, :conflict)

    assert {:error, %{reasons: [:conflict]}} = TrainingCalendar.sync()
    assert Repo.aggregate(Grant, :count) == 1
    assert [%{"role" => "writer"}] = rules(provider)

    assert {:ok, %{removed: 0}} = TrainingCalendar.sync()
    assert Repo.aggregate(Grant, :count) == 0
  end

  test "repairs a missing managed grant and uses the current Principal email", %{
    provider: provider
  } do
    person = member("old@example.com")
    assert {:ok, _} = TrainingCalendar.sync()
    Agent.update(provider, &%{&1 | rules: %{}})
    assert {:ok, %{added: 1}} = TrainingCalendar.sync()

    person.principal_id
    |> then(&Repo.get!(Principal, &1))
    |> Principal.email_changeset(%{email: "new@example.com"})
    |> Repo.update!()

    assert {:ok, %{added: 1, removed: 1}} = TrainingCalendar.sync()
    assert [%{"scope" => %{"value" => "new@example.com"}}] = rules(provider)
  end

  test "recovers an inserted share after a lost response, including revocation", %{
    provider: provider
  } do
    person = member("lost-response@example.com")
    failure(provider, {:insert, "lost-response@example.com"}, :lost_response)

    assert {:error, %{reasons: [:transient]}} = TrainingCalendar.sync()
    assert %Grant{rule_id: nil} = Repo.one!(Grant)
    assert [_] = rules(provider)
    deactivate(person)

    assert {:ok, %{added: 0, removed: 1}} = TrainingCalendar.sync()
    assert rules(provider) == []
    assert Repo.aggregate(Grant, :count) == 0
    assert [_, _] = writes(provider)
  end

  test "an unacknowledged absent insert retains its revocation obligation", %{provider: provider} do
    person = member("uncertain@example.com")
    failure(provider, {:insert, "uncertain@example.com"}, :transient)
    assert {:error, %{reasons: [:transient]}} = TrainingCalendar.sync()
    deactivate(person)

    assert {:error, %{reasons: [:uncertain_grant]}} = TrainingCalendar.sync()
    assert %Grant{rule_id: nil} = Repo.one!(Grant)
    seed_rule(provider, "uncertain@example.com")

    assert {:ok, %{removed: 1}} = TrainingCalendar.sync()
    assert rules(provider) == []
  end

  test "a lost or malformed insert acknowledgment is adopted without re-notifying", %{
    provider: provider
  } do
    for {email, reason} <- [
          {"lost@example.com", :lost_response},
          {"malformed@example.com", :malformed_ack}
        ] do
      member(email)
      failure(provider, {:insert, email}, reason)
      assert {:error, %{reasons: [:transient]}} = TrainingCalendar.sync()
      before = writes(provider)

      assert {:ok, %{added: 0}} = TrainingCalendar.sync()
      assert writes(provider) == before
      assert %Grant{rule_id: id} = Repo.get_by!(Grant, email: email)
      assert is_binary(id)
    end
  end

  test "source unlinking preserves revocation and restored eligibility can rejoin", %{
    provider: provider
  } do
    person = member("returning@example.com")
    assert {:ok, _} = TrainingCalendar.sync()
    membership = Repo.get!(MemberProfile, person.principal_id)
    Repo.delete!(membership)

    assert {:ok, %{removed: 1}} = TrainingCalendar.sync()
    assert rules(provider) == []
    Repo.insert!(membership)

    assert {:ok, %{added: 1}} = TrainingCalendar.sync()
    assert [_] = rules(provider)
  end

  test "a training target cannot expose either configured Workshop calendar" do
    original = Application.fetch_env!(:dhc, Dhc.WorkshopCalendar)
    on_exit(fn -> Application.put_env(:dhc, Dhc.WorkshopCalendar, original) end)

    for key <- [:committee_calendar_id, :participant_calendar_id] do
      Application.put_env(:dhc, Dhc.WorkshopCalendar, Keyword.put(original, key, @calendar))
      assert {:error, :configuration} = TrainingCalendar.sync()
    end
  end

  test "one rejected recipient doesn't block other additions or removals", %{provider: provider} do
    leaving = member("leaving@example.com")
    assert {:ok, _} = TrainingCalendar.sync()
    deactivate(leaving)
    member("a-rejected@example.com")
    member("z-valid@example.com")
    failure(provider, {:insert, "a-rejected@example.com"}, :rejected)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, %{failed: 1, reasons: [:rejected]}} = TrainingCalendar.sync()
      end)

    refute log =~ "a-rejected@example.com"
    refute log =~ "training-secret"
    assert [%{"scope" => %{"value" => "z-valid@example.com"}}] = rules(provider)
    assert [%Grant{email: "z-valid@example.com"}] = Repo.all(Grant)
  end

  test "an insertion conflict preserves a newly manual share rather than claiming it", %{
    provider: provider
  } do
    member("conflict@example.com")
    failure(provider, {:insert, "conflict@example.com"}, :conflict)
    assert {:error, %{reasons: [:conflict]}} = TrainingCalendar.sync()
    assert Repo.aggregate(Grant, :count) == 0
    assert {:ok, %{added: 0}} = TrainingCalendar.sync()
    assert Repo.aggregate(Grant, :count) == 0
  end

  test "failed ACL observation makes no mutations and preserves the ledger", %{provider: provider} do
    person = member("retained@example.com")
    assert {:ok, _} = TrainingCalendar.sync()
    deactivate(person)
    failure(provider, :list, :transient)
    before = writes(provider)

    assert {:error, :transient} = TrainingCalendar.sync()
    assert writes(provider) == before
    assert Repo.aggregate(Grant, :count) == 1
  end

  test "pre-existing free/busy access is reported without overriding manual sharing", %{
    provider: provider
  } do
    member("free-busy@example.com")
    seed_rule(provider, "free-busy@example.com", "freeBusyReader")
    assert {:error, %{reasons: [:insufficient_access]}} = TrainingCalendar.sync()
    assert writes(provider) == []
  end

  test "disabled and incomplete configurations never mutate or silently enable sharing", %{
    provider: provider
  } do
    member("active@example.com")
    config(enabled: false)
    assert {:ok, :disabled} = TrainingCalendar.sync()
    config(enabled: true, calendar_id: " ")
    assert {:error, :configuration} = TrainingCalendar.sync()
    config(calendar_id: "primary")
    assert {:error, :configuration} = TrainingCalendar.sync()
    config(calendar_id: @calendar, client_secret: nil)
    assert {:error, :configuration} = TrainingCalendar.sync()
    assert writes(provider) == []
  end

  test "a changed target never applies the old calendar's revocation ledger", %{
    provider: provider
  } do
    person = member("old-target@example.com")
    assert {:ok, _} = TrainingCalendar.sync()
    deactivate(person)
    config(calendar_id: "other@example.com")

    Req.Test.stub(Google, fn conn ->
      if conn.request_path == "/token" do
        Req.Test.json(conn, %{"access_token" => "access"})
      else
        assert conn.method == "GET"
        assert conn.request_path == "/calendar/v3/calendars/other%40example.com/acl"
        Req.Test.json(conn, %{"kind" => "calendar#acl", "items" => []})
      end
    end)

    assert {:ok, %{removed: 0}} = TrainingCalendar.sync()
    assert %Grant{calendar_id: @calendar} = Repo.one!(Grant)
    assert [_] = writes(provider)
  end

  defp member(email, attrs \\ []), do: MemberFixtures.member_fixture([email: email] ++ attrs)

  defp role(member, role),
    do: Repo.insert!(%UserRole{principal_id: member.principal_id, role: role})

  defp tomorrow, do: DateTime.add(DateTime.utc_now(:second), 86_400)

  defp update_member(member, attrs) do
    Repo.get!(MemberProfile, member.principal_id)
    |> Ecto.Changeset.change(attrs)
    |> Repo.update!()
  end

  defp deactivate(member) do
    Repo.get!(UserProfile, member.profile_id)
    |> Ecto.Changeset.change(is_active: false)
    |> Repo.update!()
  end

  defp config(attrs) do
    Application.put_env(
      :dhc,
      TrainingCalendar,
      Keyword.merge(Application.fetch_env!(:dhc, TrainingCalendar), attrs)
    )
  end

  defp rule(email, role, etag) do
    %{
      "id" => "user:#{email}",
      "etag" => etag,
      "role" => role,
      "scope" => %{"type" => "user", "value" => email}
    }
  end

  defp seed_rule(provider, email, role \\ "reader", etag \\ "seed") do
    rule = rule(email, role, etag)
    Agent.update(provider, &put_in(&1, [:rules, rule["id"]], rule))
  end

  defp rules(provider), do: Agent.get(provider, &Map.values(&1.rules))
  defp writes(provider), do: Agent.get(provider, &Enum.reverse(&1.writes))

  defp failure(provider, operation, reason),
    do: Agent.update(provider, &put_in(&1, [:failures, operation], reason))

  defp google(%{request_path: "/token"} = conn, _provider),
    do: Req.Test.json(conn, %{"access_token" => "access"})

  defp google(conn, provider) do
    response = Agent.get_and_update(provider, &google_response(conn, &1))

    case response do
      {:json, body} ->
        Req.Test.json(conn, body)

      {:error, status} ->
        conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"error" => "PRIVATE"})

      :transient ->
        Req.Test.transport_error(conn, :timeout)

      :deleted ->
        Plug.Conn.send_resp(conn, 204, "")
    end
  end

  defp google_response(%{method: "GET"}, state) do
    if state.failures[:list] == :transient,
      do: {:transient, state},
      else: {{:json, %{"kind" => "calendar#acl", "items" => Map.values(state.rules)}}, state}
  end

  defp google_response(%{method: "POST"} = conn, state) do
    email = conn.body_params["scope"]["value"]
    assert conn.body_params["role"] == "reader"
    assert conn.query_params == %{"sendNotifications" => "true"}
    reason = state.failures[{:insert, email}]
    revision = state.revision + 1
    rule = rule(email, "reader", "revision-#{revision}")
    state = %{state | writes: [{:insert, email} | state.writes], revision: revision}

    case reason do
      :rejected ->
        {{:error, 400}, state}

      :transient ->
        {:transient, state}

      :lost_response ->
        {:transient, put_in(state, [:rules, rule["id"]], rule)}

      :malformed_ack ->
        {{:json, %{"id" => rule["id"]}}, put_in(state, [:rules, rule["id"]], rule)}

      :conflict ->
        {{:error, 409}, put_in(state, [:rules, rule["id"]], rule)}

      nil ->
        {{:json, rule}, put_in(state, [:rules, rule["id"]], rule)}
    end
  end

  defp google_response(%{method: "DELETE"} = conn, state) do
    id = conn.request_path |> String.split("/") |> List.last() |> URI.decode_www_form()
    rule = Map.fetch!(state.rules, id)
    email = rule["scope"]["value"]
    assert Plug.Conn.get_req_header(conn, "if-match") == [rule["etag"]]

    if state.failures[{:delete, email}] == :conflict do
      changed = %{rule | "role" => "writer", "etag" => "manual-edit"}
      {{:error, 412}, put_in(state, [:rules, id], changed)}
    else
      {:deleted,
       %{state | writes: [{:delete, email} | state.writes], rules: Map.delete(state.rules, id)}}
    end
  end
end
