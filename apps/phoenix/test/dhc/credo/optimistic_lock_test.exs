defmodule Dhc.Credo.OptimisticLockTest do
  use ExUnit.Case, async: true

  alias Dhc.Credo.OptimisticLock

  setup_all do
    :ok = ensure_credo_started()
    :ok
  end

  defp ensure_credo_started do
    case Application.ensure_all_started(:credo) do
      {:ok, _started} -> :ok
      {:error, {:credo, {{:already_started, _pid}, _}}} -> :ok
    end
  end

  defp issues(source) do
    source
    |> Credo.SourceFile.parse("lib/dhc/fixture.ex")
    |> OptimisticLock.run([])
  end

  test "accepts a versioned struct write guarded by optimistic_lock" do
    assert [] =
             issues("""
             def update_item(item) do
               %Item{}
               |> Ecto.Changeset.change(quantity: 2)
               |> Ecto.Changeset.optimistic_lock(:lock_version)
               |> Repo.update()
             end
             """)
  end

  test "reports an unlocked versioned struct write" do
    [issue] =
      issues("""
      def delete_entry(id, entry) do
        Repo.get(WaitlistEntry, id)
        Repo.delete(entry)
      end
      """)

    assert issue.message =~ "optimistic_lock(:lock_version)"
    assert issue.line_no == 3
  end

  test "reports an unlocked versioned write in a private helper" do
    [issue] =
      issues("""
      defp write_pause_until(id, pause_until) do
        member_profile = Repo.get(MemberProfile, id)

        member_profile
        |> Ecto.Changeset.change(subscription_paused_until: pause_until)
        |> Repo.update()
      end
      """)

    assert issue.message =~ "optimistic_lock(:lock_version)"
    assert issue.line_no == 6
  end

  test "reports a versioned bulk write without the lock increment" do
    [issue] =
      issues("""
      def update_profiles(ids) do
        from(mp in MemberProfile, where: mp.user_profile_id in ^ids)
        |> Repo.update_all(set: [membership_end_date: nil])
      end
      """)

    assert issue.message =~ "inc: [lock_version: 1]"
  end

  test "accepts a versioned bulk write with the lock increment" do
    assert [] =
             issues("""
             def update_profiles(ids) do
               from(mp in MemberProfile, where: mp.user_profile_id in ^ids)
               |> Repo.update_all(set: [membership_end_date: nil], inc: [lock_version: 1])
             end
             """)
  end

  test "ignores writes to non-versioned entities" do
    assert [] =
             issues("""
             def update_payment_attempt(attempt) do
               attempt
               |> Ecto.Changeset.change(status: "registered")
               |> Repo.update!()
             end
             """)
  end

  test "does not attribute an unrelated write to a versioned query in the same helper" do
    assert [] =
             issues("""
             def convert(invitation, waitlist_id) do
               Repo.get(WaitlistEntry, waitlist_id)
               invitation |> Ecto.Changeset.change(status: "accepted") |> Repo.update!()
             end
             """)
  end

  test "ignores a write outside the Dhc domain source tree" do
    source_file = Credo.SourceFile.parse("Repo.delete(entry)", "test/fixture.ex")

    assert [] = OptimisticLock.run(source_file, [])
  end
end
