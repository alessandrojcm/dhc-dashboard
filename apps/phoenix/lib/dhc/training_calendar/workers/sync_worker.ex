defmodule Dhc.TrainingCalendar.Workers.SyncWorker do
  @moduledoc """
  Reconciles training calendar sharing at midnight in Dublin.

  The shared Cron plugin runs in UTC, so it wakes us at 00:00 and 23:00 UTC.
  Only the Dublin-midnight tick acts. Use the original scheduled instant, not
  execution time, so queue delays do not lose a pass. Retries always act, even
  after Oban has changed their scheduled time. Manual jobs need no cron gate.
  The uniqueness window is shorter than the one-hour gap between UTC slots:
  a queued non-midnight tick must not suppress the real midnight job. The boundary's
  database lock, rather than job uniqueness, serializes running passes.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 55 * 60, fields: [:worker], states: :incomplete]

  alias Dhc.ClubCalendar
  alias Dhc.TrainingCalendar

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    if due?(job) do
      case TrainingCalendar.sync() do
        {:ok, _result} -> :ok
        {:error, _reason} = error -> error
      end
    else
      :ok
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)

  defp due?(%Oban.Job{attempt: attempt}) when is_integer(attempt) and attempt > 1, do: true

  defp due?(%Oban.Job{meta: %{"cron" => true}, scheduled_at: %DateTime{} = at}),
    do: ClubCalendar.time_on(at).hour == 0

  defp due?(_job), do: true
end
