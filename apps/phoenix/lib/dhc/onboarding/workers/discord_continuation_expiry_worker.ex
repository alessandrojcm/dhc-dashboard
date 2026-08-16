defmodule Dhc.Onboarding.Workers.DiscordContinuationExpiryWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :invitations,
    max_attempts: 20,
    unique: [period: :infinity, fields: [:worker], states: :incomplete]

  require Logger

  alias Dhc.Onboarding

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Onboarding.expire_discord_continuations() do
      {:ok, _expired_count} ->
        :ok

      {:error, {:inconsistent_claims, continuation_ids}} = error ->
        Logger.error(
          "[discord-continuation-expiry-worker] Inconsistent Discord Claims require intervention",
          continuation_ids: continuation_ids
        )

        error
    end
  end
end
