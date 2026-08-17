defmodule Dhc.Discord.Workers.JoinGrantCleanupWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :discord,
    max_attempts: 5,
    unique: [period: :infinity, fields: [:worker], states: :incomplete]

  alias Dhc.Discord

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Discord.cleanup_expired_join_grants() do
      {:ok, _deleted_count} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
