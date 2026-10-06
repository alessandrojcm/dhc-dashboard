defmodule Dhc.TrainingAnnouncements.Workers.AnnouncementWorker do
  @moduledoc """
  Disposable driver of one Announcement Occurrence; delivery rows are the
  evidence. It only turns job arguments into an `Execution.evaluate/3` call.
  """
  use Oban.Worker, queue: :training_announcements

  alias Dhc.TrainingAnnouncements.Execution

  @impl Oban.Worker
  def perform(job, opts \\ [])

  def perform(%Oban.Job{args: %{"announcement_id" => id, "occurrence_date" => date}} = job, opts) do
    with {:ok, id} <- Ecto.UUID.cast(id), {:ok, date} <- Date.from_iso8601(date) do
      # The clock reads holiday facts (fetch-on-miss can use HTTP) before
      # Execution claims the announcement row.
      clock = Keyword.get_lazy(opts, :clock, &Execution.clock/0)
      Execution.evaluate({:announcement, id, date}, clock, job)
    else
      _ -> {:discard, :invalid_args}
    end
  end

  def perform(_job, _opts), do: {:discard, :invalid_args}
end
