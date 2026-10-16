defmodule Dhc.Notifications.RetentionTest do
  use Dhc.DataCase, async: true

  alias Dhc.Notifications.Notification
  alias Dhc.Notifications.Retention
  alias Dhc.Notifications.Workers.RetentionWorker
  alias Dhc.Repo

  @now ~U[2026-10-16 00:00:00Z]

  setup do
    %{principal: Dhc.AuthFixtures.principal_fixture()}
  end

  test "deletes read and unread notifications created more than three months ago", %{
    principal: principal
  } do
    old_unread = insert!(principal, ~U[2026-07-15 23:59:59Z])
    old_read = insert!(principal, ~U[2026-01-01 00:00:00Z], read: true)
    at_cutoff = insert!(principal, ~U[2026-07-16 00:00:00Z])
    recent = insert!(principal, ~U[2026-10-15 12:00:00Z])

    assert Retention.prune(now: @now) == 2

    refute Repo.get(Notification, old_unread)
    refute Repo.get(Notification, old_read)
    assert Repo.get(Notification, at_cutoff)
    assert Repo.get(Notification, recent)
  end

  test "uses calendar months" do
    assert Retention.cutoff(~U[2026-05-31 00:00:00Z]) == ~U[2026-02-28 00:00:00Z]
  end

  test "deletes a backlog larger than one batch", %{principal: principal} do
    old = for _ <- 1..5, do: insert!(principal, ~U[2026-01-01 00:00:00Z])
    kept = insert!(principal, @now)

    assert Retention.prune(now: @now, batch_size: 2) == 5

    assert Enum.all?(old, &is_nil(Repo.get(Notification, &1)))
    assert Repo.get(Notification, kept)
  end

  test "the worker runs a pass", %{principal: principal} do
    old = insert!(principal, DateTime.shift(DateTime.utc_now(:second), month: -4))
    kept = insert!(principal, DateTime.utc_now(:second))

    assert :ok = Oban.Testing.perform_job(RetentionWorker, %{}, repo: Repo)

    refute Repo.get(Notification, old)
    assert Repo.get(Notification, kept)
  end

  defp insert!(principal, created_at, opts \\ []) do
    read_at = if opts[:read], do: created_at

    %{id: id} =
      Repo.insert!(%Notification{
        principal_id: principal.id,
        body: "Hello",
        created_at: created_at,
        read_at: read_at
      })

    id
  end
end
