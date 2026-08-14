defmodule Dhc.Onboarding.Workers.ContinuationExpiryWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :invitations,
    max_attempts: 5,
    unique: [period: 120, fields: [:worker]]

  alias Dhc.Onboarding

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Onboarding.expire_discord_continuations() do
      {:ok, _expired_count} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
