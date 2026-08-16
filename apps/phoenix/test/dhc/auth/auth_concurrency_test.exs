defmodule Dhc.AuthConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Dhc.Auth
  alias Dhc.Auth.{ExternalIdentity, Principal, PrincipalToken}

  alias Dhc.Discord.{
    AssignmentReviewExecution,
    AssignmentStageExecution,
    AssignmentStageResult,
    StagedAssignment,
    StagedAssignmentAuditEvent
  }

  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Ecto.Adapters.SQL.Sandbox

  test "sign-in and access changes contend on the Member projection row" do
    test_process = self()
    task_supervisor = start_supervised!(Task.Supervisor)

    fixture =
      unboxed(fn ->
        fixture = Dhc.MemberFixtures.member_fixture(is_active: true)
        principal = Repo.get!(Principal, fixture.principal_id)
        {encoded_token, row} = PrincipalToken.build_magic_link_token(principal)
        Repo.insert!(row)
        Map.put(fixture, :encoded_token, encoded_token)
      end)

    on_exit(fn -> unboxed(fn -> delete_fixture(fixture.principal_id) end) end)

    locker = lock_profile(task_supervisor, fixture.profile_id, test_process)
    assert_receive {:profile_locked, locker_pid, blocker_pid}
    assert locker_pid == locker.pid

    sign_in =
      database_task(task_supervisor, test_process, :sign_in, fn ->
        Auth.consume_magic_link(fixture.encoded_token)
      end)

    assert_receive {:database_operation_started, :sign_in}
    assert_backend_blocked_by(blocker_pid)

    send(locker.pid, :release_profile)
    assert {:ok, :released} = Task.await(locker)
    assert {:ok, %{session_token: session_token}} = Task.await(sign_in)

    locker = lock_profile(task_supervisor, fixture.profile_id, test_process)
    assert_receive {:profile_locked, locker_pid, blocker_pid}
    assert locker_pid == locker.pid

    revoke =
      database_task(task_supervisor, test_process, :revoke, fn ->
        Auth.apply_member_access(fixture.profile_id, false)
      end)

    assert_receive {:database_operation_started, :revoke}
    assert_backend_blocked_by(blocker_pid)

    send(locker.pid, :release_profile)
    assert {:ok, :released} = Task.await(locker)
    assert :ok = Task.await(revoke)

    assert {:error, :invalid} =
             unboxed(fn -> Auth.get_principal_by_session_token(session_token) end)

    assert :ok = unboxed(fn -> Auth.apply_member_access(fixture.profile_id, true) end)

    encoded_token =
      unboxed(fn ->
        principal = Repo.get!(Principal, fixture.principal_id)
        {encoded_token, row} = PrincipalToken.build_magic_link_token(principal)
        Repo.insert!(row)
        encoded_token
      end)

    locker = lock_profile(task_supervisor, fixture.profile_id, test_process, false)
    assert_receive {:profile_locked, locker_pid, blocker_pid}
    assert locker_pid == locker.pid

    sign_in =
      database_task(task_supervisor, test_process, :inactive_sign_in, fn ->
        Auth.consume_magic_link(encoded_token)
      end)

    assert_receive {:database_operation_started, :inactive_sign_in}
    assert_backend_blocked_by(blocker_pid)

    send(locker.pid, :release_profile)
    assert {:ok, :released} = Task.await(locker)
    assert {:error, :inactive_membership} = Task.await(sign_in)

    assert :ok = unboxed(fn -> Auth.apply_member_access(fixture.profile_id, true) end)

    unboxed(fn ->
      principal = Repo.get!(Principal, fixture.principal_id)

      %ExternalIdentity{}
      |> ExternalIdentity.create_changeset(principal, %{
        provider: "discord",
        provider_subject: "concurrent-discord",
        metadata: %{}
      })
      |> Repo.insert!()
    end)

    locker = lock_profile(task_supervisor, fixture.profile_id, test_process)
    assert_receive {:profile_locked, locker_pid, blocker_pid}
    assert locker_pid == locker.pid

    discord_sign_in =
      database_task(task_supervisor, test_process, :discord_sign_in, fn ->
        Auth.sign_in_with_discord(%{"sub" => "concurrent-discord"})
      end)

    assert_receive {:database_operation_started, :discord_sign_in}
    assert_backend_blocked_by(blocker_pid)

    send(locker.pid, :release_profile)
    assert {:ok, :released} = Task.await(locker)
    assert {:ok, %{session_token: _token}} = Task.await(discord_sign_in)

    unboxed(fn ->
      Repo.delete_all(from(i in ExternalIdentity, where: i.principal_id == ^fixture.principal_id))
    end)

    subject = "concurrent-discord-assignment"

    assignment =
      unboxed(fn ->
        Dhc.DiscordAssignmentFixtures.approved_assignment_fixture(
          fixture.principal_id,
          subject
        )
      end)

    on_exit(fn -> unboxed(fn -> delete_assignment_fixture(assignment) end) end)

    locker = lock_profile(task_supervisor, fixture.profile_id, test_process)
    assert_receive {:profile_locked, locker_pid, blocker_pid}
    assert locker_pid == locker.pid

    discord_promotion =
      database_task(task_supervisor, test_process, :discord_promotion, fn ->
        Auth.sign_in_with_discord(%{"sub" => subject})
      end)

    assert_receive {:database_operation_started, :discord_promotion}
    assert_backend_blocked_by(blocker_pid)

    send(locker.pid, :release_profile)
    assert {:ok, :released} = Task.await(locker)
    assert {:ok, %{session_token: _token}} = Task.await(discord_promotion)
  end

  defp lock_profile(task_supervisor, profile_id, test_process, is_active \\ nil) do
    Task.Supervisor.async_nolink(task_supervisor, fn ->
      run_lock_profile_task(profile_id, test_process, is_active)
    end)
  end

  defp run_lock_profile_task(profile_id, test_process, is_active) do
    unboxed(fn ->
      Repo.transaction(fn -> lock_profile_transaction(profile_id, test_process, is_active) end)
    end)
  end

  defp lock_profile_transaction(profile_id, test_process, is_active) do
    blocker_pid = postgres_backend_pid()

    profile =
      UserProfile
      |> where([profile], profile.id == ^profile_id)
      |> lock("FOR UPDATE")
      |> Repo.one!()

    if is_boolean(is_active) do
      profile
      |> Ecto.Changeset.change(is_active: is_active)
      |> Repo.update!()
    end

    send(test_process, {:profile_locked, self(), blocker_pid})

    receive do
      :release_profile -> :released
    end
  end

  defp database_task(task_supervisor, test_process, label, fun) do
    Task.Supervisor.async_nolink(task_supervisor, fn ->
      unboxed(fn ->
        send(test_process, {:database_operation_started, label})
        fun.()
      end)
    end)
  end

  defp postgres_backend_pid do
    %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
    backend_pid
  end

  defp assert_backend_blocked_by(blocker_pid) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    do_assert_backend_blocked_by(blocker_pid, deadline)
  end

  defp do_assert_backend_blocked_by(blocker_pid, deadline) do
    directly_blocked? =
      unboxed(fn ->
        %{rows: [[directly_blocked?]]} =
          Repo.query!(
            "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE $1::integer = ANY(pg_blocking_pids(pid)))",
            [blocker_pid],
            log: false
          )

        directly_blocked?
      end)

    cond do
      directly_blocked? ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        do_assert_backend_blocked_by(blocker_pid, deadline)

      true ->
        flunk("no database backend waited directly on Member row locker #{blocker_pid}")
    end
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp delete_fixture(principal_id) do
    Repo.delete_all(from(t in PrincipalToken, where: t.principal_id == ^principal_id))
    Repo.delete_all(from(i in ExternalIdentity, where: i.principal_id == ^principal_id))

    profile_ids =
      Repo.all(from(p in UserProfile, where: p.principal_id == ^principal_id, select: p.id))

    Repo.delete_all(from(m in MemberProfile, where: m.user_profile_id in ^profile_ids))
    Repo.delete_all(from(p in UserProfile, where: p.principal_id == ^principal_id))
    Repo.delete_all(from(p in Principal, where: p.id == ^principal_id))
  end

  defp delete_assignment_fixture(assignment) do
    assignment = Repo.get!(StagedAssignment, assignment.id)

    Repo.query!(
      "ALTER TABLE staged_discord_assignment_audit_events DISABLE TRIGGER discord_assignment_reject_audit_mutation"
    )

    try do
      Repo.delete_all(
        from(e in StagedAssignmentAuditEvent, where: e.assignment_id == ^assignment.id)
      )
    after
      Repo.query!(
        "ALTER TABLE staged_discord_assignment_audit_events ENABLE TRIGGER discord_assignment_reject_audit_mutation"
      )
    end

    immutable_execution_tables = [
      "discord_assignment_stage_results",
      "discord_assignment_review_executions",
      "discord_assignment_stage_executions"
    ]

    Enum.each(immutable_execution_tables, fn table ->
      Repo.query!(
        "ALTER TABLE #{table} DISABLE TRIGGER discord_assignment_reject_execution_mutation"
      )
    end)

    try do
      Repo.delete_all(from(r in AssignmentStageResult, where: r.assignment_id == ^assignment.id))
      Repo.delete_all(from(a in StagedAssignment, where: a.id == ^assignment.id))

      if assignment.review_execution_id do
        Repo.delete_all(
          from(e in AssignmentReviewExecution, where: e.id == ^assignment.review_execution_id)
        )
      end

      Repo.delete_all(
        from(e in AssignmentStageExecution, where: e.id == ^assignment.stage_execution_id)
      )
    after
      Enum.each(immutable_execution_tables, fn table ->
        Repo.query!(
          "ALTER TABLE #{table} ENABLE TRIGGER discord_assignment_reject_execution_mutation"
        )
      end)
    end

    [assignment.prepared_by_principal_id, assignment.approved_by_principal_id]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(&delete_fixture/1)
  end
end
