defmodule Dhc.ClubCalendar.Workers.HolidayRefreshWorker do
  @moduledoc """
  ALE-319: daily refresh of the Irish bank-holiday cache.

  Re-fetches the current and next Dublin year through
  `Dhc.ClubCalendar.refresh_year/1`, which upserts by date and deletes
  cached dates the source no longer returns. A source failure leaves rows
  untouched, logs, and emits a Sentry event; the job still succeeds because
  the next daily pass (and fetch-on-miss for never-fetched years) repairs
  the miss. Retrying the whole pass would re-walk a healthy year to chase
  one bad response.

  `unique` over incomplete states keeps overlapping ticks from piling up.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker], states: :incomplete]

  alias Dhc.ClubCalendar

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    today = ClubCalendar.today()

    today.year
    |> Range.new(today.year + 1)
    |> Enum.uniq()
    |> Enum.each(&ClubCalendar.refresh_year/1)

    :ok
  end
end
