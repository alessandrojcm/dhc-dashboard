defmodule Dhc.TrainingAnnouncements.Store do
  @moduledoc """
  Internal announcement storage seam. A conditional timestamp write claims the
  current row before a command or driver re-reads it. Ordinary UPDATE semantics
  keep that write and its dependent evidence/job writes atomic with schedule
  edits, retirement and deletion; there are no explicit lock queries or lock
  tables. A stale claimant retries from a fresh snapshot, never its old struct.

  Delivery's first-freeze stamp must join this transaction seam too.
  """
  import Ecto.Query
  alias Dhc.Repo
  alias Dhc.TrainingAnnouncements.Announcement
  alias Dhc.TrainingAnnouncements.AnnouncementOverride
  alias Dhc.TrainingAnnouncements.AnnouncementSuppression

  def with_current(id, callback, retries \\ 3) do
    result =
      Repo.transaction(fn ->
        announcement = persist!(fetch(id))

        changeset = Ecto.Changeset.optimistic_lock(announcement, :updated_at, &next_timestamp/1)

        # No user fields changed yet: force the conditional write so Ecto runs
        # optimistic_lock's prepare callback instead of skipping an empty update.
        case Repo.update(changeset, stale_error_field: :updated_at, force: true) do
          {:ok, _} -> callback.(Repo.get!(Announcement, announcement.id))
          {:error, _} -> Repo.rollback(:concurrent_change)
        end
      end)

    case result do
      {:error, :concurrent_change} when retries > 0 -> with_current(id, callback, retries - 1)
      result -> result
    end
  end

  defp next_timestamp(previous) do
    now = DateTime.utc_now()

    if DateTime.compare(now, previous) == :gt,
      do: now,
      else: DateTime.add(previous, 1, :microsecond)
  end

  def fetch(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Announcement{} = announcement <- Repo.get(Announcement, id) do
      {:ok, announcement}
    else
      _ -> {:error, :not_found}
    end
  end

  def entry(announcement) do
    [entry] = entries([announcement])
    entry
  end

  def entries([]), do: []

  def entries(announcements) do
    announcement_ids = Enum.map(announcements, & &1.id)

    suppressions_by_announcement =
      Repo.all(from(s in AnnouncementSuppression, where: s.announcement_id in ^announcement_ids))
      |> Enum.group_by(& &1.announcement_id)

    overrides_by_announcement =
      Repo.all(from(o in AnnouncementOverride, where: o.announcement_id in ^announcement_ids))
      |> Enum.group_by(& &1.announcement_id)

    Enum.map(announcements, fn announcement ->
      %{
        announcement: announcement,
        suppressions: Map.get(suppressions_by_announcement, announcement.id, []),
        overrides: Map.get(overrides_by_announcement, announcement.id, [])
      }
    end)
  end

  def persist!({:ok, result}), do: result
  def persist!(:ok), do: :ok
  def persist!({:error, reason}), do: Repo.rollback(reason)
end
