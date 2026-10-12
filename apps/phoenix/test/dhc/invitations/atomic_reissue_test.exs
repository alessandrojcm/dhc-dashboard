defmodule Dhc.Invitations.AtomicReissueTest do
  use Dhc.DataCase, async: false

  alias Dhc.Invitations.Invitation
  alias Dhc.Invitations.ProcessingLog
  alias Dhc.Onboarding
  alias Ecto.Adapters.SQL.Sandbox

  @insert_barrier 7_310_042

  # Duplicate invitations are rejected while a `pending` invitation exists
  # for the email. Re-inviting is allowed again once nothing is pending.
  # The partial unique index `invitations_email_pending_unique` remains the
  # concurrency backstop for racing inserts.
  describe "Onboarding.issue_invitation/3" do
    test "rejects the invite while a pending invitation exists for the email" do
      created_by_id = insert_principal!("admin@example.com")
      invite_data = invite_data("member@example.com")

      assert {:ok, invitation_id} =
               issue(invite_data, created_by_id)

      assert {:error, :duplicate_pending_invitation} =
               issue(invite_data, created_by_id)

      # Exactly one row for the email, untouched, still pending.
      assert [%Invitation{id: ^invitation_id, status: "pending"}] =
               Repo.all(from(i in Invitation, where: i.email == "member@example.com"))
    end

    test "rejects duplicates case-insensitively" do
      created_by_id = insert_principal!("case-admin@example.com")

      assert {:ok, _original_id} =
               issue(invite_data("Member@Example.com"), created_by_id)

      assert {:error, :duplicate_pending_invitation} =
               issue(invite_data("member@example.com"), created_by_id)

      assert 1 ==
               Repo.aggregate(
                 from(i in Invitation, where: i.email == "MEMBER@example.com"),
                 :count
               )
    end

    test "allows re-inviting once no pending invitation remains" do
      created_by_id = insert_principal!("reinvite-admin@example.com")
      invite_data = invite_data("lapsed@example.com")

      assert {:ok, original_id} =
               issue(invite_data, created_by_id)

      Repo.update_all(
        from(i in Invitation, where: i.id == ^original_id),
        set: [status: "expired"]
      )

      assert {:ok, replacement_id} =
               issue(invite_data, created_by_id)

      refute replacement_id == original_id

      assert %Invitation{status: "pending"} = Repo.get!(Invitation, replacement_id)
      assert %Invitation{status: "expired"} = Repo.get!(Invitation, original_id)
    end

    test "concurrent duplicate invites fail loud instead of creating two pending invitations" do
      email = "atomic-reissue-#{System.unique_integer([:positive])}@example.com"
      invite_data = invite_data(email)
      admin_email = "atomic-admin-#{System.unique_integer([:positive])}@example.com"
      created_by_id = outside_sandbox(fn -> insert_principal!(admin_email) end)

      # The trigger parks each matching INSERT on an advisory lock the test
      # holds, so both creates have finished their pre-insert reads before
      # either inserts. Releasing the lock lets them race on the insert itself.
      outside_sandbox(fn ->
        Repo.query!("""
        CREATE OR REPLACE FUNCTION park_pending_invitation_for_concurrency_test() RETURNS trigger AS $$
        BEGIN
          IF NEW.email::text LIKE 'atomic-reissue-%' THEN
            PERFORM pg_advisory_lock_shared(#{@insert_barrier});
            PERFORM pg_advisory_unlock_shared(#{@insert_barrier});
          END IF;
          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql
        """)

        Repo.query!("""
        CREATE TRIGGER park_pending_invitation_for_concurrency_test
        BEFORE INSERT ON invitations
        FOR EACH ROW EXECUTE FUNCTION park_pending_invitation_for_concurrency_test()
        """)
      end)

      on_exit(fn ->
        outside_sandbox(fn ->
          Repo.delete_all(from i in Invitation, where: i.email == ^email)
          Repo.delete_all(from l in ProcessingLog, where: l.principal_id == ^created_by_id)
          Repo.delete_all(from p in Dhc.Auth.Principal, where: p.id == ^created_by_id)

          Repo.delete_all(from j in Oban.Job, where: fragment("?->>'email'", j.args) == ^email)

          Repo.query!(
            "DROP TRIGGER IF EXISTS park_pending_invitation_for_concurrency_test ON invitations"
          )

          Repo.query!("DROP FUNCTION IF EXISTS park_pending_invitation_for_concurrency_test()")
        end)
      end)

      test_process = self()

      barrier =
        Task.async(fn ->
          outside_sandbox(fn ->
            Repo.query!("SELECT pg_advisory_lock($1)", [@insert_barrier])
            send(test_process, :barrier_held)
            receive do: (:release -> :ok)
            Repo.query!("SELECT pg_advisory_unlock($1)", [@insert_barrier])
          end)
        end)

      assert_receive :barrier_held, 5_000

      creates =
        for _ <- 1..2 do
          Task.async(fn ->
            outside_sandbox(fn ->
              issue(invite_data, created_by_id)
            end)
          end)
        end

      try do
        await_barrier_waiters(2)
      after
        send(barrier.pid, :release)
      end

      Task.await(barrier, 5_000)
      results = Enum.map(creates, &Task.await(&1, 10_000))

      assert 1 == Enum.count(results, &match?({:ok, _invitation_id}, &1))
      assert 1 == Enum.count(results, &match?({:error, _reason}, &1))

      assert 1 ==
               outside_sandbox(fn ->
                 Repo.aggregate(
                   from(i in Invitation, where: i.email == ^email and i.status == "pending"),
                   :count
                 )
               end)
    end
  end

  defp outside_sandbox(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp issue(invite_data, created_by_id) do
    Repo.transaction(fn ->
      case Onboarding.issue_invitation(invite_data, created_by_id) do
        {:ok, %{invitation_id: id}} -> id
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp await_barrier_waiters(expected, attempts \\ 200) do
    waiting =
      outside_sandbox(fn ->
        %{rows: [[count]]} =
          Repo.query!(
            """
            SELECT count(*) FROM pg_locks
            WHERE locktype = 'advisory' AND NOT granted
              AND classid = 0 AND objid = $1 AND objsubid = 1
            """,
            [@insert_barrier],
            log: false
          )

        count
      end)

    cond do
      waiting >= expected ->
        :ok

      attempts > 0 ->
        Process.sleep(10)
        await_barrier_waiters(expected, attempts - 1)

      true ->
        flunk("expected #{expected} inserts parked on the barrier, saw #{waiting}")
    end
  end

  defp insert_principal!(email) do
    id = Ecto.UUID.generate()
    {:ok, _principal} = Dhc.Auth.register_principal_with_id(id, %{email: email})
    id
  end

  defp invite_data(email) do
    %{
      "firstName" => "Ada",
      "lastName" => "Lovelace",
      "email" => email,
      "phoneNumber" => "+353810000001",
      "dateOfBirth" => "1990-01-01"
    }
  end
end
