defmodule Dhc.AuthConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Dhc.Auth
  alias Dhc.Auth.{ExternalIdentity, Principal, PrincipalToken}
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
    assert_receive {:profile_locked, locker_pid}
    assert locker_pid == locker.pid

    sign_in =
      database_task(task_supervisor, test_process, :sign_in, fn ->
        Auth.consume_magic_link(fixture.encoded_token)
      end)

    assert_receive {:database_backend, :sign_in, backend_pid}
    assert_backend_waiting_on_lock(backend_pid)

    send(locker.pid, :release_profile)
    assert {:ok, :released} = Task.await(locker)
    assert {:ok, %{session_token: session_token}} = Task.await(sign_in)

    locker = lock_profile(task_supervisor, fixture.profile_id, test_process)
    assert_receive {:profile_locked, locker_pid}
    assert locker_pid == locker.pid

    revoke =
      database_task(task_supervisor, test_process, :revoke, fn ->
        Auth.apply_member_access(fixture.profile_id, false)
      end)

    assert_receive {:database_backend, :revoke, backend_pid}
    assert_backend_waiting_on_lock(backend_pid)

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
    assert_receive {:profile_locked, locker_pid}
    assert locker_pid == locker.pid

    sign_in =
      database_task(task_supervisor, test_process, :inactive_sign_in, fn ->
        Auth.consume_magic_link(encoded_token)
      end)

    assert_receive {:database_backend, :inactive_sign_in, backend_pid}
    assert_backend_waiting_on_lock(backend_pid)

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
    assert_receive {:profile_locked, locker_pid}
    assert locker_pid == locker.pid

    discord_sign_in =
      database_task(task_supervisor, test_process, :discord_sign_in, fn ->
        Auth.sign_in_with_discord(%{"sub" => "concurrent-discord"})
      end)

    assert_receive {:database_backend, :discord_sign_in, backend_pid}
    assert_backend_waiting_on_lock(backend_pid)

    send(locker.pid, :release_profile)
    assert {:ok, :released} = Task.await(locker)
    assert {:ok, %{session_token: _token}} = Task.await(discord_sign_in)

    unboxed(fn ->
      Repo.delete_all(from(i in ExternalIdentity, where: i.principal_id == ^fixture.principal_id))
    end)

    locker = lock_profile(task_supervisor, fixture.profile_id, test_process)
    assert_receive {:profile_locked, locker_pid}
    assert locker_pid == locker.pid

    discord_link =
      database_task(task_supervisor, test_process, :discord_link, fn ->
        principal = Repo.get!(Principal, fixture.principal_id)

        Auth.sign_in_with_discord(%{
          "sub" => "concurrent-discord-new",
          "email" => principal.email,
          "email_verified" => true
        })
      end)

    assert_receive {:database_backend, :discord_link, backend_pid}
    assert_backend_waiting_on_lock(backend_pid)

    send(locker.pid, :release_profile)
    assert {:ok, :released} = Task.await(locker)
    assert {:ok, %{session_token: _token}} = Task.await(discord_link)
  end

  defp lock_profile(task_supervisor, profile_id, test_process, is_active \\ nil) do
    Task.Supervisor.async_nolink(task_supervisor, fn ->
      unboxed(fn ->
        Repo.transaction(fn ->
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

          send(test_process, {:profile_locked, self()})

          receive do
            :release_profile -> :released
          end
        end)
      end)
    end)
  end

  defp database_task(task_supervisor, test_process, label, fun) do
    Task.Supervisor.async_nolink(task_supervisor, fn ->
      unboxed(fn ->
        %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
        send(test_process, {:database_backend, label, backend_pid})
        fun.()
      end)
    end)
  end

  defp assert_backend_waiting_on_lock(backend_pid) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    do_assert_backend_waiting_on_lock(backend_pid, deadline)
  end

  defp do_assert_backend_waiting_on_lock(backend_pid, deadline) do
    waiting? =
      unboxed(fn ->
        case Repo.query!(
               "SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1",
               [backend_pid]
             ).rows do
          [["Lock"]] -> true
          _rows -> false
        end
      end)

    cond do
      waiting? ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        do_assert_backend_waiting_on_lock(backend_pid, deadline)

      true ->
        flunk("database backend #{backend_pid} did not wait on the Member row lock")
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
end
