defmodule Dhc.OnboardingConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Dhc.Invitations.Invitation
  alias Dhc.Onboarding
  alias Dhc.Onboarding.InvitationAcceptanceAttempt
  alias Dhc.Onboarding.InvitationAcceptanceAttempts
  alias Dhc.Onboarding.InvitationAcceptanceDiscordContinuation
  alias Dhc.Repo
  alias Ecto.Adapters.SQL.Sandbox

  test "concurrent browser proofs create exactly one active Attempt and Continuation" do
    test_process = self()
    task_supervisor = start_supervised!(Task.Supervisor)
    invitation = unboxed(&insert_invitation!/0)

    on_exit(fn ->
      unboxed(fn ->
        InvitationAcceptanceAttempts.purge_for_invitation(invitation.id)
        Repo.delete!(Repo.get!(Invitation, invitation.id))
      end)
    end)

    locker =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            Invitation
            |> where([record], record.id == ^invitation.id)
            |> lock("FOR UPDATE")
            |> Repo.one!()

            send(test_process, :invitation_locked)

            receive do
              :release_invitation -> :released
            end
          end)
        end)
      end)

    assert_receive :invitation_locked

    starts =
      for label <- [:first, :second] do
        Task.Supervisor.async_nolink(task_supervisor, fn ->
          unboxed(fn ->
            %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
            send(test_process, {:database_backend, label, backend_pid})

            Onboarding.start_acceptance(
              invitation.id,
              invitation.email,
              Date.to_iso8601(invitation.date_of_birth)
            )
          end)
        end)
      end

    for label <- [:first, :second] do
      assert_receive {:database_backend, ^label, backend_pid}
      assert_backend_waiting_on_lock(backend_pid)
    end

    send(locker.pid, :release_invitation)
    assert {:ok, :released} = Task.await(locker)

    results = Enum.map(starts, &Task.await/1)

    assert 1 == Enum.count(results, &match?({:ok, _state}, &1))
    assert 1 == Enum.count(results, &match?({:error, :missing_browser_proof}, &1))

    unboxed(fn ->
      assert Repo.aggregate(
               from(attempt in InvitationAcceptanceAttempt,
                 where: attempt.invitation_id == ^invitation.id
               ),
               :count
             ) == 1

      assert Repo.aggregate(
               from(continuation in InvitationAcceptanceDiscordContinuation,
                 where: continuation.invitation_id == ^invitation.id
               ),
               :count
             ) == 1
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
        flunk("database backend #{backend_pid} did not wait on the Invitation row lock")
    end
  end

  defp insert_invitation! do
    %Invitation{
      email: "onboarding-concurrency-#{System.unique_integer([:positive])}@example.com",
      prospective_principal_id: Ecto.UUID.generate(),
      status: "pending",
      expires_at: DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second),
      invitation_type: "member",
      first_name: "Ada",
      last_name: "Lovelace",
      phone_number: "+353810000000",
      date_of_birth: ~D[1990-01-01]
    }
    |> Repo.insert!()
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
