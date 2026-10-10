defmodule Dhc.Waitlist.StandingTest do
  use Dhc.DataCase, async: true

  alias Dhc.Repo
  alias Dhc.Waitlist
  alias Dhc.Waitlist.Standing
  alias Dhc.Waitlist.WaitlistEntry

  # The whole ALE-375 transition table. Anything not listed is refused.
  @legal [
    {"waiting", "removed"},
    {"waiting", "attended"},
    {"removed", "waiting"},
    {"removed", "attended"},
    {"attended", "removed"},
    {"attended", "invited"},
    {"invited", "attended"},
    {"invited", "joined"}
  ]

  @statuses ~w(waiting removed attended invited joined)

  test "Waitlist Status has exactly the five standings" do
    assert Standing.statuses() == @statuses
  end

  test "the database enum is the five standings" do
    %{rows: [[labels]]} =
      Repo.query!("SELECT enum_range(NULL::waitlist_status)::text[]")

    assert labels == @statuses
  end

  for from <- @statuses, to <- @statuses do
    @from from
    @to to
    @legal? {from, to} in @legal

    test "#{from} → #{to} is #{if @legal?, do: "allowed", else: "refused"}" do
      assert Standing.allowed?(@from, @to) == @legal?

      entry = insert_entry!(@from)
      result = in_transaction(fn -> Waitlist.change_standing(entry.id, @to) end)

      if @legal? do
        assert {:ok, %WaitlistEntry{status: @to}} = result
        assert Repo.get!(WaitlistEntry, entry.id).status == @to
      else
        assert {:error, :illegal_standing_change} = result
        assert Repo.get!(WaitlistEntry, entry.id) == entry
      end
    end
  end

  test "entering removed starts the retention clock and leaving it clears it" do
    entry = insert_entry!("waiting")
    assert entry.removed_at == nil

    {:ok, removed} = in_transaction(fn -> Waitlist.change_standing(entry.id, "removed") end)
    assert %DateTime{} = removed.removed_at
    assert removed.last_status_change == removed.removed_at
    assert Repo.get!(WaitlistEntry, entry.id).removed_at == removed.removed_at

    {:ok, restored} = in_transaction(fn -> Waitlist.change_standing(entry.id, "waiting") end)
    assert restored.removed_at == nil
    assert Repo.get!(WaitlistEntry, entry.id).removed_at == nil
  end

  test "the database refuses a removed standing without its timestamp" do
    entry = insert_entry!("waiting")

    assert_raise Postgrex.Error, ~r/waitlist_removed_at_matches_status/, fn ->
      Repo.query!("UPDATE waitlist SET status = 'removed' WHERE id = $1", [
        Ecto.UUID.dump!(entry.id)
      ])
    end
  end

  test "commits and rolls back with the caller's transaction" do
    entry = insert_entry!("waiting")

    assert {:error, :caller_failed} =
             Repo.transaction(fn ->
               {:ok, _} = Waitlist.change_standing(entry.id, "removed")
               Repo.rollback(:caller_failed)
             end)

    assert Repo.get!(WaitlistEntry, entry.id).status == "waiting"
  end

  test "refuses to run outside a transaction" do
    entry = insert_entry!("waiting")

    assert_raise ArgumentError, ~r/inside a transaction/, fn ->
      Waitlist.change_standing(entry.id, "removed")
    end

    assert Repo.get!(WaitlistEntry, entry.id).status == "waiting"
  end

  test "returns not_found for an unknown entry" do
    assert {:error, :not_found} =
             in_transaction(fn -> Waitlist.change_standing(Ecto.UUID.generate(), "removed") end)
  end

  defp in_transaction(fun) do
    {:ok, result} = Repo.transaction(fun)
    result
  end

  defp insert_entry!(status) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %WaitlistEntry{
      email: "#{Ecto.UUID.generate()}@example.com",
      status: status,
      removed_at: if(status == "removed", do: now),
      initial_registration_date: now,
      last_status_change: now
    }
    |> Repo.insert!()
    |> then(&Repo.get!(WaitlistEntry, &1.id))
  end
end
