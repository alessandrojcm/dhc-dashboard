defmodule Dhc.TrainingAnnouncements.Workers.DeliveryPruneWorker do
  @moduledoc "Prunes delivery evidence older than 400 Dublin days, preserving retired announcements."
  use Oban.Worker, queue: :training_announcements

  import Ecto.Query

  alias Dhc.Repo
  alias Dhc.TrainingAnnouncements
  alias Dhc.TrainingAnnouncements.Announcement
  alias Dhc.TrainingAnnouncements.DiscordAnnouncementDelivery

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    horizon = TrainingAnnouncements.retention_horizon()
    retired = from(a in Announcement, where: a.retired, select: a.id)

    DiscordAnnouncementDelivery
    |> where([d], d.occurrence_date < ^horizon or d.holiday_date < ^horizon)
    |> where([d], is_nil(d.announcement_id) or d.announcement_id not in subquery(retired))
    |> Repo.delete_all()

    :ok
  end
end
